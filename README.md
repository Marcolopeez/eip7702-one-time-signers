# Ephemeral Key Account

Experimental EIP-7702 account prototype using one-time ECDSA authorization keys and one-time ECDSA recovery keys.

This repository is research-oriented. It is **not production-ready wallet software** and must not be used to secure real assets without further review, threat modeling, key-storage work, and adversarial testing.

## Overview

The project explores a minimal smart-account model where an EOA delegates execution to `EphemeralKeyAccount.sol` through EIP-7702. When the implementation executes as delegated code:

```text
address(this) == delegated EOA
storage       == delegated EOA storage
code          == implementation code
```

The contract stores signer **addresses**, not public keys. The TypeScript wallet derives and manages the corresponding ECDSA private keys off-chain.

The core security experiment is a post-quantum-inspired threat model: once an ECDSA signature is observed, the corresponding private key must be treated as exposed. Therefore, every authorization key is intended to be used exactly once.

A normal operation is signed by the current authorization key and commits to the next authorization key:

```text
auth[i] signs Operation(
  target,
  value,
  data,
  nextAuthorizedSigner = auth[i+1],
  deadline
)
```

After a valid signature is verified, the contract rotates to `auth[i+1]` before validating or executing the external call. If the external call fails, the whole transaction must not revert, because reverting would roll back the rotation while the signature from `auth[i]` has already been exposed.

## Repository layout

```text
src/
  EphemeralKeyAccount.sol           EIP-7702 delegated account implementation.

script/
  DeployImplementation.s.sol        Deploys the reusable implementation.
  InitializeDelegatedAccount.s.sol  Attaches delegation and initializes the EOA storage.
  DeployExecutionTarget.s.sol       Deploys the local execution target used in tests.

scripts/
  README.md                         Local E2E script documentation.
  run-local-e2e.sh                  Full Anvil/Foundry/wallet E2E flow.

test/
  EphemeralKeyAccount7702Test.t.sol Foundry tests for delegated execution and recovery.
  mocks/ExecutionTarget.sol         Target contract used to test calls and reverts.

wallet/
  README.md                         Wallet module documentation.
  src/account/                      EIP-712, client, state machine, sync, key selection.
  src/crypto/                       Deterministic signer derivation.
  src/storage/                      JSON-backed local state store.
  src/cli/                          Developer CLI flows.
  test/                             TypeScript unit tests.

docs/
  README.md                         Design notes, threat model, invariants, limitations.
```

## Architecture

```text
BIP-39 mnemonic + walletId
        |
        v
wallet/ TypeScript module
  derives one-time auth/recovery signer streams
  signs EIP-712 Operation / RecoveryOperation messages
  burns keys locally at signing time
  persists pending signatures before broadcast
  reconciles local state from on-chain storage
        |
        v
relayer transaction
  pays gas but does not authorize the operation
        |
        v
delegated EOA using EphemeralKeyAccount code
  verifies EIP-712 signatures against address(this)
  rotates signers before external execution
  returns failure data instead of reverting after valid signatures
  pauses if rotation cannot safely install the next signer
  uses one-time recovery keys to restore the account
```

The wallet and contract deliberately split responsibilities:

| Responsibility | Enforced by |
|---|---|
| Signature validity | Contract |
| Current signer rotation | Contract |
| Preventing on-chain signer reuse | Contract `isConsumedOrReservedSigner` |
| Avoiding reuse of locally signed keys | Wallet local state |
| Selecting fresh next keys | Wallet + on-chain reads |
| Treating pending signatures as burned | Wallet |
| Recovery from `PAUSED` | Contract + wallet |
| Secure key storage | Not implemented |

## Threat model

This prototype assumes an adversary that may eventually recover an ECDSA private key after observing a valid signature from that key. Under this model:

- an ECDSA key must be considered unsafe immediately after signing;
- a signed operation can consume a key even if its target call fails;
- expired operations and invalid targets may still rotate the signer;
- recovery keys must also be one-time keys;
- reverting after a valid signature can be dangerous if it restores an already-exposed signer.

The contract does **not** protect against compromise of the native EIP-7702 authority key that controls the EOA delegation at protocol level. If that authority key is recovered from a set-code authorization or otherwise compromised, an attacker may be able to replace or clear the delegation outside this contract's control. This is an important out-of-scope risk for the current experiment.

See [`docs/README.md`](docs/README.md) for the detailed design notes and limitations.

## Operation lifecycle

The normal relayed flow is:

1. Wallet syncs local state with delegated-account storage.
2. Wallet derives the current auth signer from `currentAuthIndex`.
3. Wallet searches for a fresh `nextAuthorizedSigner` that is not locally burned and not consumed/reserved on-chain.
4. Wallet builds an `Operation` with target call data and `nextAuthorizedSigner`.
5. Wallet signs EIP-712 typed data using the current auth private key.
6. Wallet immediately marks the current auth index as burned and persists `PENDING_OPERATION` before broadcasting.
7. Relayer submits `executeSignedAndRotate(operation, signature)`.
8. Contract verifies the signature against `currentAuthorizedSigner`.
9. Contract rotates or pauses before validating/executing the target.
10. Wallet waits for inclusion and then syncs from contract storage.

The receipt status is not enough to understand the semantic outcome. The account function can return `(success = false, result)` while the Ethereum transaction itself succeeds and security-relevant state changes persist.

## Recovery lifecycle

Recovery uses active one-time recovery signers. The current implementation supports both:

- `rotateAuthorizedSignerThroughRecovery(nextAuthorizedSigner, nextRecoverySigner)`, called directly by an active recovery signer;
- `signedRecovery(RecoveryOperation, signature)`, submitted by a relayer with an EIP-712 signature from an active recovery signer.

A successful recovery:

1. consumes the current recovery signer;
2. installs a fresh authorized signer;
3. registers a fresh recovery signer;
4. unpauses the account if it was paused.

The wallet currently restricts recovery signing to locally `PAUSED` accounts. The contract is more permissive: active recovery keys can rotate the account even when it is not paused. This is intentional in the contract tests, but wallet UX should treat recovery as an emergency flow unless a broader policy is added.

## Basic commands

From the repository root:

```bash
forge build
forge test
```

From `wallet/`:

```bash
pnpm install
pnpm typecheck
pnpm test
```

Run the automated local E2E flow from the repository root:

```bash
./scripts/run-local-e2e.sh
```

The E2E script starts Anvil with the Prague hardfork, deploys the implementation, attaches EIP-7702 delegation, initializes the delegated account, runs normal and edge-case wallet flows, triggers pause, performs recovery, and writes logs under `.e2e/`.

## Current implementation status

Implemented:

- EIP-7702-oriented delegated account contract;
- initialization of delegated EOA storage;
- one-time authorized signer rotation;
- non-reverting failure semantics after valid authorization;
- pause-on-invalid-next-authorized-signer behavior;
- one-time recovery signer consumption and renewal;
- EIP-712 operation and recovery signing;
- deterministic `auth` and `recovery` signer derivation;
- local wallet state machine with burned-key tracking;
- lookahead-based key selection using on-chain signer status;
- viem-based read/write client and relayer submission;
- local JSON state persistence for development;
- Foundry tests and TypeScript unit tests;
- local E2E flow.

Not implemented / not production-ready:

- secure enclave, hardware wallet, or encrypted key storage;
- encrypted local state;
- browser extension, mobile app, or user-facing UI;
- multi-device coordination;
- event indexing or durable transaction history;
- production recovery UX;
- ERC-4337 `EntryPoint`, bundler, paymaster, or gas sponsorship;
- formal verification;
- production-grade mempool, replacement, and dropped-transaction handling.

## Documentation

- [`docs/README.md`](docs/README.md): architecture, threat model, invariants, failure semantics, limitations, and future work.
- [`wallet/README.md`](wallet/README.md): TypeScript wallet module, key derivation, local state, sync, and CLI flows.
- [`scripts/README.md`](scripts/README.md): local E2E workflow and environment.
