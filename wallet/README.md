# Wallet Module

The `wallet/` package contains the TypeScript wallet logic for the `EphemeralKeyAccount` experiment.

It is not a full wallet application. It is a developer-oriented module that derives one-time signers, signs EIP-712 account operations, persists local key-consumption state, sends local transactions through a relayer, and reconciles state with the delegated account contract.

## Responsibilities

The wallet currently handles:

1. deterministic derivation of `auth` and `recovery` signer streams;
2. EIP-712 hashing and signing for `Operation` and `RecoveryOperation`;
3. local state transitions and burned-key tracking;
4. selection of unused next auth/recovery signers;
5. RPC reads and writes through viem;
6. reconciliation of local state against on-chain storage;
7. local CLI flows for initialization, execution, pause testing, and recovery.

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
  eip712.ts              EIP-712 domain, typed-data definitions, signing, hashing, recovery.
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
  hex.ts                 Small hex and byte helpers.

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
auth[i]      normal operation signer
recovery[i]  recovery operation signer
```

The derivation context includes:

- mnemonic;
- optional BIP-39 passphrase;
- `walletId`;
- `chainId`;
- delegated account address;
- implementation address;
- logical account index.

The `auth` stream is bound to `walletId`, which represents a specific wallet installation. The `recovery` stream is not bound to `walletId`, so it can be reconstructed from the mnemonic and passphrase if the installation state is lost.

All signer paths are hardened-only. The wallet does not expose xpub/watch-only derivation because every leaf is a signing key that may become exposed after one signature.

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

The EIP-712 verifying contract is the delegated EOA, not the implementation address. This matches EIP-7702 execution, where `address(this)` in delegated code is the EOA.

## Local state machine

`src/account/state.ts` stores the wallet-side state for one delegated account.

Main statuses:

```text
READY              normal operation signing is allowed
PENDING_OPERATION  an auth signature was produced and must be reconciled
PAUSED             normal signing is blocked; recovery is required
PENDING_RECOVERY   a recovery signature was produced and must be reconciled
```

When an operation is signed, the current auth index is added to `burnedAuthIndices`. When a recovery operation is signed, the current recovery index is added to `burnedRecoveryIndices`.

This is not just UI state. It is part of the security model: a locally burned key must not be used again even if the transaction is dropped, expires, returns `(false, result)`, or the target reverts.

## Synchronization

`src/account/sync.ts` contains pure reconciliation logic. It does not talk to RPC.

`src/account/client.ts` reads an on-chain snapshot through viem and passes it to `reconcileLocalState(...)`.

The wallet reconciles by reading contract storage such as:

```text
isInitialized()
isPaused()
currentAuthorizedSigner()
isConsumedOrReservedSigner(address)
isActiveRecoverySigner(address)
```

This is intentional. The wallet must not assume that transaction receipt status alone describes the account state. In this project, a transaction can succeed at the Ethereum receipt level while the account function returns `(success = false, result)` after still performing security-relevant state transitions.

## Key selection

`src/account/keySelection.ts` searches forward through derived keys and checks both local and on-chain status.

For auth keys, the wallet skips:

- locally burned indices;
- signers already consumed or reserved on-chain.

For recovery keys, the wallet also requires the candidate recovery signer to be inactive on-chain.

The default lookahead window is intentionally finite. If no safe candidate is found, the wallet stops instead of guessing.

## Local storage

`src/storage/localStore.ts` stores `LocalWalletState` as JSON, usually under:

```text
wallet/.local/state.json
```

This is development storage only. It is not encrypted and is not suitable as production key or state storage.

The store writes through a temporary file and rename step to reduce the chance of leaving a partially written state file.

## CLI flows

The CLI scripts are local developer entrypoints.

Typical local setup:

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

The scripts expect environment variables such as `MNEMONIC`, `WALLET_ID`, `RPC_URL`, `RELAYER_PRIVATE_KEY`, and, depending on the script, deployed contract addresses. See the root README and `scripts/README.md` for the full local E2E flow.

## Common commands

From `wallet/`:

```bash
pnpm install
pnpm typecheck
pnpm test
```

The automated root E2E script also runs these commands before executing the full local flow.

## Current limitations

The wallet module currently assumes a local/developer environment and has several important limitations:

- no UI;
- no secure enclave or hardware wallet integration;
- no encrypted local state;
- no multi-device coordination;
- no production-grade recovery UX;
- no event indexing or full transaction history;
- no ERC-4337 bundler or paymaster integration;
- JSON state is used for development convenience only.

The module is useful for validating the account model and local execution flows, not for managing real assets.
