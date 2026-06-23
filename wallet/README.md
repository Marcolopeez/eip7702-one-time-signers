# Wallet Module

The `wallet/` package contains the TypeScript wallet logic for the `EphemeralKeyAccount` experiment.

It is not a full wallet application. It is a developer-oriented module for deriving one-time signers, signing EIP-712 account operations, tracking locally burned keys, submitting transactions through a relayer, and reconciling wallet state with delegated-account storage.

## Responsibilities

The wallet currently implements:

1. deterministic `auth` and `recovery` signer derivation;
2. EIP-712 hashing/signing for `Operation` and `RecoveryOperation`;
3. local state transitions for one-time-key consumption;
4. lookahead-based selection of unused next signers;
5. viem-based reads and writes;
6. relayer submission for signed operations and signed recovery;
7. local JSON state persistence;
8. CLI flows for local initialization, execution, pause testing, sync, and recovery.

The core wallet rule is:

```text
Producing a signature burns the corresponding local key immediately.
```

This applies before broadcasting, before receipt confirmation, and regardless of whether the external target call succeeds.

## Folder layout

```text
src/account/
  abi.ts                 ABI for EphemeralKeyAccount.
  client.ts              viem-based RPC client for reads, writes, receipts, and sync.
  eip712.ts              EIP-712 domain, typed data definitions, signing, hashing, recovery.
  executionTargetAbi.ts  ABI for the local ExecutionTarget test contract.
  keySelection.ts        Lookahead-based selection of unused auth/recovery signers.
  state.ts               Local wallet state machine and burned-key transitions.
  sync.ts                Pure reconciliation from on-chain snapshots to local state.
  types.ts               Shared operation and signing types.

src/cli/
  prepare-local-init.ts          Derives initial signers and writes init files.
  create-initial-state.ts        Creates local state after on-chain initialization.
  sync.ts                        Reads contract storage and updates local state.
  execute-set-number.ts          Executes a normal setNumber operation.
  execute-target-revert.ts       Executes an operation whose target reverts.
  execute-expired-set-number.ts  Executes an expired operation with valid rotation.
  execute-invalid-next-auth.ts   Dev-only invalid next signer pause test.
  recover.ts                     Performs signed recovery from PAUSED state.
  derive-demo.ts                 Prints derived signer addresses.
  sign-demo.ts                   Demonstrates EIP-712 signing and signer recovery.
  env.ts                         Environment-variable helpers.

src/crypto/
  derivation.ts          Deterministic auth/recovery signer derivation.
  hex.ts                 Hex and byte validation helpers.

src/storage/
  localStore.ts          JSON-backed local state persistence.

test/
  derivation.test.ts
  eip712.test.ts
  state.test.ts
  sync.test.ts
```

## Key derivation

`src/crypto/derivation.ts` derives two independent one-time ECDSA signer streams:

```text
auth[i]      signer for normal account operations
recovery[i]  signer for recovery operations
```

The derivation context includes:

- BIP-39 mnemonic;
- optional BIP-39 passphrase;
- `walletId`;
- `chainId`;
- delegated account address;
- implementation address;
- logical account index.

The `auth` stream is bound to `walletId`, which represents a specific wallet installation. The `recovery` stream is not bound to `walletId`, so it can be reconstructed from mnemonic + passphrase if the installation state is lost.

Implemented path format:

```text
auth[i]      m / 7702' / 60' / accountIndex' / 0' / i'
recovery[i]  m / 7702' / 60' / accountIndex' / 1' / i'
```

Before BIP-32 derivation, the module applies HKDF-SHA256 to separate:

- wallet-bound root;
- recovery root;
- account context;
- auth/recovery stream master seeds.

The account context binds derived keys to:

```text
chainId | delegatedAccount | implementationAddress | accountIndex
```

This avoids accidentally reusing the same one-time signer across chains, delegated accounts, or implementations.

All signer paths are hardened-only. The wallet does not expose xpub/watch-only derivation because every leaf is a signing key that may become exposed after one signature.

### Design implications of `walletId`

`walletId` is expected to be a 32-byte per-install identifier.

- Same mnemonic + same `walletId` derives the same auth stream.
- Same mnemonic + different `walletId` derives a different auth stream.
- Losing `walletId` means the active auth stream may not be reconstructible.
- Recovery does not depend on `walletId`, so mnemonic + passphrase can recover into a new wallet stream.

Multi-device active signing is out of scope. Two devices sharing the same mnemonic and `walletId` could sign with the same current auth key unless an additional coordination mechanism exists.

## EIP-712 signing

`src/account/eip712.ts` mirrors the typed data expected by `EphemeralKeyAccount.sol`.

Normal operations are signed as:

```text
Operation(
  address target,
  uint256 value,
  bytes32 dataHash,
  address nextAuthorizedSigner,
  uint256 deadline
)
```

The wallet signs `dataHash = keccak256(data)`, not raw `bytes data`.

Recovery operations are signed as:

```text
RecoveryOperation(
  address nextAuthorizedSigner,
  address nextRecoverySigner,
  uint256 deadline
)
```

The EIP-712 domain is:

```text
name              EphemeralKeyAccount
version           1
chainId           state.chainId
verifyingContract state.delegatedAccount
```

The verifying contract is the delegated EOA, not the implementation address. This matches the EIP-7702 execution model where contract code runs with `address(this)` equal to the EOA.

The signing helpers are intentionally low-level. They do not burn keys by themselves. Production flows must call them through `state.ts` so key consumption is persisted immediately after signing.

## Local state machine

`src/account/state.ts` stores wallet-side state for one delegated account.

Statuses:

```text
READY              normal operation signing is allowed
PENDING_OPERATION  an auth signature was produced and must be reconciled
PAUSED             normal signing is blocked; recovery is required
PENDING_RECOVERY   a recovery signature was produced and must be reconciled
```

A pending operation records:

```text
consumedAuthIndex
consumedAuthSigner
nextAuthIndex
nextAuthorizedSigner
operationDigest
signature
signedAtUnix
txHash?
```

A pending recovery records:

```text
consumedRecoveryIndex
consumedRecoverySigner
nextAuthIndex
nextAuthorizedSigner
nextRecoveryIndex
nextRecoverySigner
recoveryDigest
signature
signedAtUnix
txHash?
```

When an operation is signed, the current auth index is added to `burnedAuthIndices`. When a recovery operation is signed, the current recovery index is added to `burnedRecoveryIndices`.

This is not UI state. It is part of the security model: a burned key must not be used again even if the transaction is dropped, expires, returns `(false, result)`, or the target reverts.

## Operation flow

The normal CLI operation flow is implemented in `execute-set-number.ts`, `execute-target-revert.ts`, and `execute-expired-set-number.ts`:

1. Load local state.
2. Sync with delegated-account storage before signing.
3. Require `status == READY`.
4. Derive the current auth signer from `currentAuthIndex`.
5. Check that the derived address matches `currentAuthorizedSigner` in local state.
6. Select a fresh `nextAuthorizedSigner` with `findNextUnusedAuthSigner()`.
7. Build the `Operation`.
8. Sign EIP-712 typed data with the current auth private key.
9. Persist `PENDING_OPERATION` and burn the current auth index before broadcasting.
10. Relayer sends `executeSignedAndRotate(operation, signature)`.
11. Attach `txHash` after broadcast.
12. Wait for receipt.
13. Sync from contract storage.

Important: receipt `success` is not interpreted as account-level success. The contract may return `(false, result)` while the Ethereum transaction succeeds and signer rotation persists.

## Failure semantics from the wallet perspective

### Target revert

If the target reverts, the contract returns `(success = false, result = targetRevertData)`. The auth signer is still consumed and the account should advance to the next auth signer if rotation succeeded.

### Expired operation

An expired operation can still rotate if the signature is valid and `nextAuthorizedSigner` is valid. The target is not called. The wallet must still treat the consumed auth key as burned.

### Invalid next auth signer

A valid signature with an invalid `nextAuthorizedSigner` causes the contract to enter `PAUSED`. The consumed auth key stays burned locally. Recovery is required.

The production path `beginOperationSigning()` rejects zero or repeated next signers locally. `beginUnsafeOperationSigningForPauseTest()` exists only to exercise the contract's pause path in local tests and requires a `DEV_ONLY` reason.

### Dropped or pending transaction

If a transaction is not mined, the local state remains `PENDING_OPERATION` or `PENDING_RECOVERY`. The wallet must not sign a second operation with the same key. A real wallet needs explicit UX for rebroadcasting, replacement, cancellation-by-recovery, or waiting.

## Recovery flow

The CLI recovery flow is implemented in `recover.ts`.

1. Load local state.
2. Sync with delegated-account storage before signing.
3. Require `status == PAUSED`.
4. Derive the current recovery signer from `currentRecoveryIndex`.
5. Check that it matches local state and is active on-chain.
6. Select a fresh auth signer, skipping burned and consumed/reserved signers.
7. Select a fresh recovery signer, requiring inactive and not consumed/reserved.
8. Build `RecoveryOperation(nextAuthorizedSigner, nextRecoverySigner, deadline)`.
9. Sign EIP-712 typed data with the current recovery key.
10. Persist `PENDING_RECOVERY` and burn the current recovery index before broadcasting.
11. Relayer sends `signedRecovery(recoveryOperation, signature)`.
12. Sync from contract storage.

A successful sync moves the wallet back to `READY` and advances both streams.

The contract also supports direct recovery through `rotateAuthorizedSignerThroughRecovery(...)`, but the current wallet CLI uses signed recovery via relayer.

## Synchronization

`src/account/sync.ts` contains pure reconciliation logic. It does not perform RPC calls.

`src/account/client.ts` reads an on-chain snapshot through viem and passes it to `reconcileLocalState(...)`.

The wallet reads:

```text
isInitialized()
isPaused()
currentAuthorizedSigner()
isConsumedOrReservedSigner(address)
isActiveRecoverySigner(address)
```

For pending recovery, extra reads distinguish:

- recovery tx not mined yet;
- recovery signer consumed but account still paused;
- full recovery success;
- critical partial recovery where auth advanced but no fresh recovery signer became active.

The sync layer deliberately throws `SyncInvariantError` if local and on-chain state cannot be reconciled safely. Signing should stop rather than guessing a new cursor.

## Key selection

`src/account/keySelection.ts` searches forward from a start index using a bounded lookahead window.

For auth signers, the wallet rejects candidates that are:

- locally burned;
- consumed or reserved on-chain.

For recovery signers, the wallet rejects candidates that are:

- locally burned;
- consumed or reserved on-chain;
- already active on-chain.

The default lookahead is finite. If no safe candidate is found, the wallet fails closed.

## Local storage

`src/storage/localStore.ts` stores `LocalWalletState` as JSON, usually under:

```text
wallet/.local/state.json
```

This is development storage only. It is not encrypted and is not suitable for production key or state storage.

The store writes through a temporary file followed by rename to reduce partial-write risk during local development.

## CLI commands

Setup and state:

```bash
pnpm prepare:init
pnpm state:init
pnpm sync
```

Execution flows:

```bash
pnpm execute:set-number
pnpm execute:target-revert
pnpm execute:expired-set-number
pnpm execute:invalid-next-auth
pnpm recover
```

Demos:

```bash
pnpm derive:demo
pnpm sign:demo
```

Common development checks:

```bash
pnpm install
pnpm typecheck
pnpm test
```

The scripts expect environment variables such as `MNEMONIC`, `WALLET_ID`, `RPC_URL`, `RELAYER_PRIVATE_KEY`, and deployed contract addresses. The root E2E script wires these values automatically for local Anvil tests.

## Wallet invariants

A correct wallet implementation should preserve at least these invariants:

1. Never sign unless local state has been synced recently.
2. Never sign while status is `PENDING_OPERATION` or `PENDING_RECOVERY`.
3. Never use a burned auth or recovery index again.
4. Never use a zero address as next auth or recovery signer.
5. Never install a locally burned signer as `nextAuthorizedSigner`.
6. Never install an on-chain consumed/reserved signer as `nextAuthorizedSigner`.
7. Never register an active, consumed, reserved, or burned signer as `nextRecoverySigner`.
8. Persist pending state before broadcasting the relayer transaction.
9. Treat expired operations as potentially key-consuming.
10. Stop signing on `SyncInvariantError`.

## Current limitations

The wallet module currently assumes a local/developer environment and has important limitations:

- no UI;
- no secure enclave or hardware wallet integration;
- no encrypted local state;
- raw private keys are returned in memory by the derivation layer;
- no multi-device coordination;
- no production transaction replacement or dropped-transaction UX;
- no event indexing or full transaction history;
- JSON state is used for development convenience only.

The module is useful for validating the account model and local execution flows, not for managing real assets.

## Internal SDK boundary

The wallet now exposes a small core SDK in `src/core/`.

The browser extension should call this layer instead of reimplementing signing
or state transitions in UI code:

```ts
const wallet = new EphemeralWallet({
  mnemonic,
  passphrase,
  store,
  client,
});

await wallet.sync();
await wallet.execute({ target, value, data });
await wallet.recover();
```

The SDK enforces the critical sequence:

```text
sync -> derive -> sign -> burn locally -> persist -> broadcast -> wait -> sync
```

That means a key is marked as burned in persistent state immediately after a
signature is produced and before the transaction is broadcast. Popup/UI code in
the future browser wallet must not call `signOperation()` or
`signRecoveryOperation()` directly.
