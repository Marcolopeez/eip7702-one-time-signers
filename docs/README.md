# Design Notes

This document describes the design decisions behind `OneTimeSignerAccount` and the companion TypeScript wallet.

## Motivation

The experiment studies a minimal EIP-7702 account controlled by rotating ECDSA signers.

The motivating threat model is post-quantum-inspired: if a cryptographically relevant quantum computer can recover an ECDSA private key after observing a valid signature, then a conventional Ethereum account has a problem. Once a key signs, it may no longer be safe to keep using that key.

This project explores one mitigation at the account layer:

```text
Each authorization key should be valid for exactly one authorization.
```

A signed operation does not only authorize an action. It also commits to the next authorization key.

## Design goals

The implemented design prioritizes these properties:

1. A valid signature from the current auth signer must consume that signer.
2. Rotation must happen before external execution.
3. Failures after a valid signature should not revert state that protects key consumption.
4. If a valid signature requests an invalid next auth signer, the account should pause instead of reverting.
5. In `PAUSED`, normal auth-key execution is blocked.
6. Recovery keys are also one-time ECDSA keys.
7. Wallet state must burn keys at signing time, not at transaction confirmation time.
8. EIP-712 signatures must be bound to the delegated EOA, not the implementation contract.
9. Contract storage must be interpreted as delegated EOA storage under EIP-7702.

Non-goals for this version:

- production key custody;
- multi-device wallet synchronization;
- ERC-4337 integration;
- advanced policy engines or scoped session permissions;
- batching;
- social recovery UX;
- proving full post-quantum security.

## EIP-7702 execution model

`OneTimeSignerAccount.sol` is deployed once as an implementation contract. An EOA then delegates to that implementation through EIP-7702.

During delegated execution:

```text
address(this) = delegated EOA
msg.sender    = external caller / relayer / direct signer, depending on the function
storage       = delegated EOA storage
code          = implementation code
```

This has several consequences:

- The EIP-712 `verifyingContract` must be the delegated EOA address.
- `domainSeparator()` intentionally uses `address(this)`.
- `initialize()` writes to the delegated EOA's storage, not the implementation's storage.
- The implementation contract itself should not be used directly.

The contract enforces this with `onlyDelegatedAccount`, which compares `address(this)` against an immutable implementation address captured at deployment time.

## On-chain architecture

The delegated account stores a small amount of state:

```text
isInitialized
isPaused
currentAuthorizedSigner
isConsumedOrReservedSigner[address]
isActiveRecoverySigner[address]
```

The contract stores signer addresses only. The wallet owns the mapping from deterministic private keys to addresses.

### Initialization

`initialize(firstAuthorizedSigner, initialRecoverySigners)`:

- must be called through the delegated EOA;
- can only run once;
- requires `msg.sender == address(this)`;
- rejects zero first auth signer;
- reserves the delegated account address itself;
- reserves the first auth signer;
- reserves and activates each initial recovery signer.

The local setup script currently initializes one recovery signer, although the contract accepts an array.

### Normal execution

`executeSignedAndRotate(operation, signature)`:

1. reverts if the account is uninitialized or paused;
2. recovers the signer from the EIP-712 operation signature;
3. reverts if the signature is not from `currentAuthorizedSigner`;
4. attempts to rotate to `operation.nextAuthorizedSigner`;
5. pauses and returns `(false, encodedError)` if the next signer is invalid;
6. validates `target` and `deadline` after rotation;
7. calls `target` only after rotation and operation validation;
8. returns target success/revert data without reverting solely because the target reverted.

Invalid signatures revert because no valid current-key signature has been observed. After a valid current-key signature has been observed, expected failures are returned instead of reverted.

### Direct auth rotation

`rotateAuthorizedSigner(nextAuthorizedSigner)` allows the current auth signer to rotate without executing a target call. This path is useful for rotation-only flows, but it is not relayer-friendly because the current auth signer is the transaction sender and pays gas.

Like signed execution, invalid next signers pause instead of reverting because the direct transaction signature from the current signer is observable.

### Recovery

There are two recovery entrypoints:

```text
rotateAuthorizedSignerThroughRecovery(nextAuthorizedSigner, nextRecoverySigner)
signedRecovery(RecoveryOperation, signature)
```

Both consume the recovery signer before validating replacement signers.

A successful recovery:

- deactivates the consumed recovery signer;
- installs `nextAuthorizedSigner`;
- unpauses the account if needed;
- validates and activates `nextRecoverySigner`;
- returns `(true, "")`.

If `nextAuthorizedSigner` is invalid, recovery returns `(false, encodedError)` and the account remains paused. The recovery key is still consumed.

If `nextAuthorizedSigner` is valid but `nextRecoverySigner` is invalid, the current implementation installs the new auth signer and unpauses, then returns `(false, encodedError)` without registering a fresh recovery signer. The wallet treats this as a critical partial-recovery state during sync. Production designs should either prevent this state at the contract level or define an explicit recovery policy for it.

## Wallet architecture

The wallet package is not a full application. It is a developer module with four main layers:

```text
crypto/derivation.ts
  deterministic auth/recovery signer derivation

account/eip712.ts
  typed-data hashing, signing, and signer recovery

account/state.ts
  local account state machine and burned-key transitions

account/sync.ts + account/client.ts
  on-chain reads, relayed writes, and reconciliation
```

The wallet does not rely on receipt status as the final source of truth. It reads delegated-account storage and reconciles local state from that snapshot.

## Key management

The current implementation derives two deterministic ECDSA streams:

```text
auth[i]      normal operation signers
recovery[i]  recovery operation signers
```

Both streams are derived from:

- BIP-39 mnemonic;
- optional BIP-39 passphrase;
- chain ID;
- delegated account address;
- implementation address;
- logical account index.

The `auth` stream is additionally bound to `walletId`, a 32-byte per-install identifier. The `recovery` stream is not bound to `walletId`, so mnemonic + passphrase can reconstruct recovery signers if the installation state is lost.

Implemented path format:

```text
auth:     m / 7702' / 60' / accountIndex' / 0' / i'
recovery: m / 7702' / 60' / accountIndex' / 1' / i'
```

All path levels are hardened. The wallet does not expose xpub/watch-only derivation because every leaf is a signing key and may be treated as exposed after one signature.

Before BIP-32 derivation, the code applies HKDF-SHA256 for explicit domain separation:

```text
rootSeed       = BIP39(mnemonic, passphrase)
walletRoot     = HKDF(rootSeed, salt = walletId, info = "...:wallet-root")
recoveryRoot   = HKDF(rootSeed, fixed salt, info = "...:recovery-root")
accountContext = chainId | delegatedAccount | implementationAddress | accountIndex
streamSeed     = HKDF(streamRoot, salt = accountContext, info = "...:<stream>:bip32-master-seed")
```

Design implication:

- Losing `walletId` means the active auth stream may not be reconstructible.
- Recovery is intended to rotate the account to a new wallet installation stream.
- Two devices with the same mnemonic and same `walletId` can derive the same auth keys and risk double use.
- Multi-device active signing is therefore out of scope for this prototype.

## Local wallet state

The wallet persists one `LocalWalletState` per delegated account:

```text
schemaVersion
chainId
delegatedAccount
implementationAddress
walletId
accountIndex
status
currentAuthIndex
currentAuthorizedSigner
currentRecoveryIndex
currentRecoverySigner
burnedAuthIndices
burnedRecoveryIndices
pendingOperation?
pendingRecovery?
updatedAtUnix
```

Supported statuses:

```text
READY              normal signing allowed
PENDING_OPERATION  auth signature produced; waiting for reconciliation
PAUSED             normal signing blocked; recovery required
PENDING_RECOVERY   recovery signature produced; waiting for reconciliation
```

The critical local rule is:

```text
Producing a signature burns the corresponding local key immediately.
```

This happens before broadcasting and before a transaction receipt exists. The state file is saved as `PENDING_OPERATION` or `PENDING_RECOVERY` before the relayer transaction is sent.

## Key selection

`keySelection.ts` scans deterministic streams with a bounded lookahead window. It refuses to guess indefinitely.

For next auth signers, the wallet skips:

- locally burned indices;
- signers already consumed or reserved on-chain.

For next recovery signers, the wallet skips:

- locally burned indices;
- signers already consumed or reserved on-chain;
- signers already active on-chain.

This is necessary because `isConsumedOrReservedSigner` is the contract's durable replay-prevention set.

## Failure semantics

The distinction between revert and returned failure is central to the design.

### Reverts are acceptable before valid key exposure

The contract may revert when:

- it is called directly on the implementation;
- the account is uninitialized;
- the account is paused and a normal flow is attempted;
- initialization is invalid;
- a signed operation recovers a signer different from `currentAuthorizedSigner`;
- a recovery signature is not from an active recovery signer.

In these cases, the contract has not accepted a valid current authorization that must be preserved.

### Returned failures preserve key consumption

After a valid current-key authorization is observed, the contract should not revert for expected semantic failures. Instead it returns `(false, result)`.

Examples:

- invalid `nextAuthorizedSigner` after valid auth signature;
- expired operation after successful rotation;
- zero target after successful rotation;
- target call revert after successful rotation;
- expired recovery after valid recovery signature;
- invalid recovery replacement signer after recovery signer consumption.

This means a failed operation may still consume a key or advance the signer. That is intentional.

## Security invariants

Important invariants currently represented in code and tests:

1. The implementation contract storage should remain unused for delegated account state.
2. The delegated account can be initialized only once.
3. `currentAuthorizedSigner` cannot be zero.
4. The delegated account address itself is reserved and cannot become a signer.
5. Initial auth and recovery signers are reserved.
6. A consumed or reserved signer cannot become a future auth signer.
7. A valid signed operation rotates before target execution.
8. Target revert does not roll back auth rotation.
9. Expired operations rotate if the next auth signer is valid, but skip target execution.
10. Invalid next auth signer after valid authorization pauses the account.
11. In `PAUSED`, normal signed execution and direct auth rotation are blocked.
12. Recovery signer consumption happens before replacement validation.
13. Consumed recovery signers cannot be reused.
14. Successful recovery rotates both auth and recovery streams.
15. EIP-712 signatures are bound to the delegated EOA via `verifyingContract`.
16. The wallet burns keys locally at signing time.
17. The wallet refuses to sign while another operation or recovery is pending.
18. The wallet stops on unreconciled local/on-chain state instead of guessing.

## Known limitations

### EIP-7702 authority key remains a protocol-level risk

This contract controls the delegated account's internal authorization policy. It does not remove the native ECDSA authority key that can install or replace EIP-7702 delegation.

A production design must address how the authority key is generated, stored, used, and retired after delegation.

### Local storage is not secure storage

`JsonLocalStore` is development storage only. It stores security-sensitive state such as burned indices, pending signatures, and signer cursors. It is not encrypted and has no secure enclave integration.

### Private keys exist in application memory

`deriveSigner()` returns raw private keys to the signing layer. This is acceptable for the prototype but not for production wallet software.

### No multi-device coordination

The local state machine assumes one active signer stream. Multi-device support requires coordination to prevent two devices from signing different operations with the same current auth key.

### Pending transaction handling is minimal

The wallet persists pending signatures and can sync state after inclusion, but production-grade handling of dropped transactions, replacement policies, relayer failures, chain reorgs, and mempool observation is not implemented.

### Partial recovery requires stronger policy

The contract can enter a partial recovery state if `nextAuthorizedSigner` is valid but `nextRecoverySigner` is invalid. The wallet detects this as a critical sync invariant violation. Future versions should either make recovery replacement validation all-or-paused, or document and handle an explicit no-recovery-signer state.

### Recovery UX is prototype-only

The contract supports multiple initial recovery signers and recovery-signer renewal, but the wallet CLI currently models a simple single-active-recovery flow for local testing.

## Testing strategy

Current tests cover the most important contract and wallet properties:

- delegated storage vs implementation storage;
- initialization restrictions;
- direct auth rotation;
- relayed signed execution;
- target reverts without global revert;
- expired operations;
- invalid next signer pause behavior;
- paused-state restrictions;
- direct and signed recovery;
- recovery signer consumption and replay failure;
- EIP-712 domain binding to the delegated EOA;
- deterministic derivation;
- local state transitions;
- sync reconciliation and invariant errors.

Useful next testing additions:

- property-based tests for arbitrary operation/recovery sequences;
- fuzzing of `nextAuthorizedSigner` and `nextRecoverySigner` combinations;
- explicit tests for local crash windows around signing and broadcast;
- dropped/replaced transaction simulations;
- multi-relayer duplicate submission scenarios;
- event-driven reconstruction tests;
- chain reorg scenarios;
- tests for multiple initial recovery signers in the wallet layer.

## Roadmap / future work

Potential next steps:

- document authority-key lifecycle after EIP-7702 delegation;
- add secure key custody abstraction;
- encrypt local state and separate private key material from state metadata;
- implement explicit transaction replacement and pending-operation recovery flows;
- add event indexing for account history reconstruction;
- add diagrams for operation, pause, and recovery lifecycles;
- introduce ADRs for derivation, recovery policy, and failure semantics;
- refine partial recovery semantics at the contract level;
- add optional multi-recovery-key policy;
- explore post-quantum or hybrid recovery mechanisms;
