# Threat Model

## Status

This project is an experimental research prototype.

It is not production-ready, has not been audited for production use, and must not be used with real assets. The model described here is intentionally narrow: it explores a partial post-quantum threat model for ECDSA-based accounts using EIP-7702 and one-time signer keys.

## Core assumption

The project assumes a CRQC-capable adversary may be able to break ECDSA after observing a valid ECDSA signature from a key.

In this model, a valid observed signature is treated as exposure of the corresponding ECDSA key. It does not matter whether the transaction succeeds, reverts at the target, expires, or is only partially applied. Once the signature exists outside the wallet, the key must be considered unsafe.

This is not full post-quantum security. The account still uses ECDSA. The goal is narrower: reduce the time window in which an observed ECDSA signature remains useful.

## Security objective

The main protected property is:

> An authorized ECDSA key must not remain valid after a valid signature from that key has been observed.

The account and wallet are designed around this rule:

* signing consumes the current key;
* the account rotates to a fresh signer before executing external calls;
* if safe rotation is not possible, the account pauses;
* paused accounts require recovery;
* recovery keys are also one-time keys.

## System model

The prototype has two cooperating parts:

* `src/OneTimeSignerAccount.sol`

  * minimal account implementation intended to run as delegated code through EIP-7702;
  * stores account state in the delegated EOA storage;
  * validates EIP-712 signatures;
  * rotates signers;
  * pauses when a valid signature has exposed the current key but no safe next signer can be installed;
  * supports recovery through active one-time recovery signers.

* `wallet/`

  * TypeScript wallet prototype;
  * derives signer streams off-chain;
  * signs EIP-712 operations;
  * persists local key-consumption state immediately after signing;
  * syncs local state against on-chain account storage;
  * refuses to sign when local and on-chain state cannot be reconciled safely.

The contract stores signer addresses, not raw private keys. Each signer address is expected to correspond to a fresh one-time ECDSA keypair managed by the wallet.

## Attacker capabilities

The threat model assumes an attacker may be able to:

* observe valid ECDSA signatures in the mempool, transaction history, relayer logs, or other broadcast paths;
* use CRQC capabilities to recover the ECDSA key after observing a valid signature;
* replay previously observed signatures;
* submit signed operations as an untrusted relayer;
* delay, drop, reorder, or front-run submitted transactions;
* call public account functions directly when they have a valid signature or control the expected signer;
* provide malicious targets that revert, return arbitrary data, or attempt reentrant behavior;

The design assumes attackers can observe signatures. It does not rely on signature secrecy after signing.

## Out of scope

This prototype does not protect against:

* compromise of the EIP-7702 authority key that controls delegation at protocol level;
* replacement, clearing, or malicious modification of the EOA delegation outside this contract’s control;
* compromise of the mnemonic, browser extension, local storage, build pipeline, or developer machine;
* malicious wallet UI behavior or phishing;
* unsafe target contract logic;
* loss of funds caused by intentionally signing malicious calldata;
* chain reorgs, censorship, transaction non-inclusion, or denial of service;
* full post-quantum security;
* production-grade key custody, backups, or recovery UX;

Implementation note: the Solidity account explicitly documents that it cannot protect against compromise of the EIP-7702 authority key. That limitation is central to the threat model.

## One-time signer model

The normal authorization stream uses `currentAuthorizedSigner`.

A valid operation must be signed by the current authorized signer. After the signature is verified, the account attempts to rotate to `operation.nextAuthorizedSigner` before validating the executable part of the operation and before calling the external target.

This order is intentional:

1. verify signature;
2. consume the current signer by rotating to the next signer;
3. validate operation fields such as target and deadline;
4. call the external target.

The current signer is considered exposed as soon as the signature is valid. Therefore, failures after signature verification must not roll back signer consumption.

A signer cannot be reused if it is already marked in `isConsumedOrReservedSigner`.

The wallet mirrors this rule locally. Once it produces an operation signature, it moves to `PENDING_OPERATION`, records the pending operation, and burns the local auth index before broadcasting. The wallet must persist this state before submitting the transaction.

## Recovery signer model

Recovery uses active one-time recovery signers tracked by `isActiveRecoverySigner`.

A valid recovery operation installs:

* a fresh `nextAuthorizedSigner`;
* a fresh `nextRecoverySigner`.

The recovery signer is consumed as soon as a valid recovery signature is observed. This happens before checking whether the recovery operation is expired or whether the requested replacement signers are valid.

Recovery keys follow the same CRQC rule as normal auth keys:

> If a recovery key signs once, it must not be usable again.

A consumed recovery signer is deactivated and remains reserved through `isConsumedOrReservedSigner`.

Implementation note: the contract supports recovery rotation even when the account is not paused. The current wallet prototype restricts recovery signing to local `PAUSED` state. 

Implementation note: if `nextAuthorizedSigner` is valid but `nextRecoverySigner` is invalid, the contract rotates the authorized signer and unpauses the account, but does not register a fresh recovery signer. The wallet sync logic treats this as a critical partial recovery and refuses to reconcile silently.

## EIP-7702 and EIP-712 implications

`OneTimeSignerAccount` is designed to be used as delegated code through EIP-7702.

Under EIP-7702:

* `address(this)` is the delegated EOA;
* storage belongs to the delegated EOA;
* the implementation contract only provides code;
* the EOA behaves as a minimal smart account.

The implementation contract protects against direct use by checking that execution is happening through delegation. Direct calls to the implementation contract must not initialize or mutate implementation storage.

EIP-712 signatures are bound to the delegated EOA, not to the implementation contract.

The EIP-712 domain uses:

```text
name: OneTimeSignerAccount
version: 1
chainId: current chain id
verifyingContract: address(this)
```

When called through EIP-7702, `address(this)` is the delegated EOA. This matters because two EOAs may use the same implementation code but must not accept each other’s signatures.

Using the implementation contract address as `verifyingContract` would weaken account separation and could allow signatures to be valid in contexts they were not intended for.

## Critical invariants

These invariants define the project’s security model:

1. An ECDSA key that has signed must not control the account again.
2. No failure after a valid signature may revert the already-applied signer rotation.
3. If the account cannot rotate to a valid next signer, it must enter paused mode.
4. In paused mode, normal authorized execution must be blocked.
5. Recovery keys are one-time keys.
6. Any observed valid signature is equivalent to key exposure in the CRQC threat model.
7. EIP-712 `verifyingContract` must be the delegated EOA.
8. Under EIP-7702, `address(this)` must be treated as the delegated EOA, not the implementation contract.
9. The wallet must persist local key-consumption state immediately after signing and before broadcast.
10. Transaction receipts are not final wallet state.
11. The final source of truth after a transaction is on-chain account storage read through `sync()`.
12. If local state and on-chain state cannot be safely reconciled, the wallet must refuse to sign.
13. Used, consumed, or reserved signers must never become valid again.
14. Dev-only unsafe signing paths must not be used in normal wallet flows.

## Failure scenarios

### External target revert

If the external target reverts, the account must not revert the whole account transaction only because of that target failure.

Expected behavior:

* the signature is verified;
* the signer rotates first;
* the target call is attempted;
* the function returns `(success = false, result = target revert data)`;
* the new signer remains installed;
* the account remains unpaused.

Security implication: target failure must not resurrect the exposed key.

### Invalid next signer

If a valid operation signature requests an invalid `nextAuthorizedSigner`, the current key has already been exposed but the account cannot safely rotate.

Invalid examples include:

* zero address;
* a signer already consumed or reserved;
* the delegated account address itself, because it is reserved during initialization.

Expected behavior:

* the account pauses;
* the target is not called;
* `currentAuthorizedSigner` remains unchanged on-chain;
* normal execution is blocked until recovery.

This is an emergency state. Even though `currentAuthorizedSigner` remains the same, the key is considered exposed and must not be used again by the wallet.

### Expired operation

An expired operation still contains a valid signature.

Expected behavior:

* the signature is verified;
* the signer rotates to the next authorized signer if the next signer is valid;
* the operation returns `(success = false, result = ExpiredOperation)`;
* the external target is not called;
* the account does not pause solely because the operation expired.

Security implication: expiration prevents execution, not key exposure. The key is still burned.

### Replay attempt

A replayed normal operation should fail because the account has already advanced to a different `currentAuthorizedSigner`.

Expected behavior:

* replaying an old auth signature recovers the old signer;
* the old signer no longer matches `currentAuthorizedSigner`;
* the call reverts with invalid signature;
* account state is not modified by the replay.

A replayed recovery signature should fail because the recovery signer has already been consumed and deactivated.

EIP-712 also binds signatures to the chain id and delegated account address, reducing cross-chain and cross-account replay risk.

### Local/on-chain state divergence

The wallet must not infer final state from a transaction receipt.

A successful Ethereum receipt may still correspond to a function-level failure such as:

```text
(success = false, result = encoded error)
```

The wallet must call `sync()` and reconcile against on-chain storage.

Safe reconciliation examples:

* `PENDING_OPERATION` to `READY` when on-chain signer advanced to the expected next signer;
* `PENDING_OPERATION` to `PAUSED` when the account paused;
* `PENDING_RECOVERY` to `READY` when both the authorized signer and recovery signer advanced as expected;
* `PENDING_RECOVERY` to `PAUSED` when the recovery key was consumed but recovery failed.

Unsafe reconciliation must stop signing. Examples include:

* local `READY` signer differs from on-chain signer;
* local `PAUSED` state but on-chain account is unexpectedly unpaused;
* pending operation resolves to an unexpected signer;
* partial recovery where the authorized signer advanced but the expected next recovery signer is not active.

In these cases, the wallet should fail closed.

### Paused account

Paused mode means the account cannot safely continue with normal authorized execution.

Expected behavior:

* `executeSignedAndRotate` reverts with `AccountIsPaused`;
* direct authorized rotation reverts with `AccountIsPaused`;
* receiving ETH is still allowed;
* recovery remains available.

Security implication: paused mode prevents an exposed signer from continuing the normal auth chain.

### Recovery path

Recovery is the only intended path out of local `PAUSED` state.

Expected behavior for successful recovery:

* active recovery signer signs a recovery operation;
* recovery signer is consumed immediately;
* fresh authorized signer is installed;
* fresh recovery signer is registered;
* account is unpaused;
* wallet sync moves back to `READY`.

Expected behavior for failed recovery:

* recovery signer is still consumed;
* expired recovery returns failure and leaves account paused;
* invalid next authorized signer returns failure and leaves account paused;
* invalid next recovery signer may leave the account unpaused with the authorized signer advanced but without the expected recovery signer registered.

The last case is treated as critical by the wallet. Do not rely on partial recovery as a normal state.

## Where to go next

* [`../README.md`](../README.md): repository entry point and basic commands.
* [`README.md`](./README.md): documentation index.
* [`00-quickstart.md`](./00-quickstart.md): local setup and first run.
* [`01-overview.md`](01-overview.md): conceptual entry point. 
* :pushpin: **[`02-threat-model.md`](./02-threat-model.md): threat model, assumptions, and security invariants.**
* [`03-architecture.md`](./03-architecture.md): system architecture and trust boundaries.
* [`04-contract.md`](./04-contract.md): Solidity account behavior.
* [`05-wallet-architecture.md`](./05-wallet-architecture.md): TypeScript wallet internals.
* [`06-cli.md`](./06-cli.md): CLI commands and local workflows.
* [`07-browser-wallet.md`](./07-browser-wallet.md): browser extension prototype.
* [`08-testing.md`](./08-testing.md): Foundry, Vitest, and local E2E validation.