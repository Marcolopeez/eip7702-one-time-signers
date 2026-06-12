# Ephemeral Key Account

This repository is an experimental Ethereum account project built around EIP-7702 delegation, one-time ECDSA authorization keys, and one-time recovery keys.

The code is research-oriented. It is not production-ready wallet software.

## What this project contains

The repository has three main parts:

1. **Delegated account contract** — `src/EphemeralKeyAccount.sol`
2. **Foundry tests and local deployment scripts** — `test/`, `script/`, and `scripts/`
3. **TypeScript wallet module** — `wallet/`

Together, these components test an EIP-7702 flow where an EOA delegates execution to `EphemeralKeyAccount.sol`, while the wallet derives ephemeral signing keys, signs EIP-712 operations, tracks burned keys locally, and reconciles its state with on-chain storage.

## Core idea

`EphemeralKeyAccount.sol` is designed to be used as delegated code through EIP-7702.

In that execution mode:

```text
address(this) == delegated EOA
storage       == delegated EOA storage
code          == implementation code
```

The delegated account stores signer **addresses**, not public keys. The off-chain wallet is responsible for deriving and managing the corresponding ECDSA keys.

A normal operation is signed by the current authorized signer and includes the next authorized signer:

```text
auth[i] signs Operation(
  target, 
  value,
  data,
  nextAuthorizedSigner = auth[i+1],
  deadline
  )
```

After a valid signature is verified, the account attempts to rotate away from `auth[i]` before executing the external call. If the external target fails, the account should not revert the whole transaction, because that would roll back the key rotation while the signature from `auth[i]` has already been exposed.

If rotation cannot safely install the next signer, the account enters `PAUSED`. In that state, normal execution is blocked and recovery is required.

Recovery also uses one-time ECDSA keys:

```text
recovery[j] signs RecoveryOperation(
  nextAuthorizedSigner = auth[k],
  nextRecoverySigner   = recovery[j+1],
  deadline
)
```

A successful recovery consumes `recovery[j]`, installs a fresh authorized signer, registers a fresh recovery signer, and returns the account to `READY`.

## High-level architecture

```text
Foundry / Anvil
  deploy implementation
  attach EIP-7702 delegation
  initialize delegated account
        |
        v
EphemeralKeyAccount.sol
  verifies EIP-712 signatures
  rotates one-time auth signers
  pauses on unsafe rotation failures
  consumes and renews recovery signers
        |
        v
wallet/
  derives auth/recovery signer streams
  signs Operation and RecoveryOperation messages
  burns keys locally at signing time
  sends transactions through a relayer
  reconciles local state from on-chain storage
        |
        v
scripts/run-local-e2e.sh
  validates the full local flow end to end
```

The wallet intentionally does not rely only on transaction receipt status. The final source of truth is the delegated account storage read through `sync()`.

## Project layout

```text
src/
  EphemeralKeyAccount.sol          EIP-7702 delegated account implementation.

script/
  DeployImplementation.s.sol       Deploys the account implementation.
  InitializeDelegatedAccount.s.sol Attaches delegation and initializes the EOA.
  DeployExecutionTarget.s.sol      Deploys a target contract for local execution tests.

scripts/
  run-local-e2e.sh                 Automated local Anvil/Foundry/wallet E2E flow.

test/
  EphemeralKeyAccount7702Test.t.sol Foundry tests for delegated account behavior.
  mocks/ExecutionTarget.sol         Local target used to test calls and reverts.

wallet/
  src/account/                     Account client, EIP-712, local state, sync, key selection.
  src/cli/                         Developer CLI scripts for local flows.
  src/crypto/                      Deterministic auth/recovery signer derivation.
  src/storage/                     JSON-backed local state persistence.
  test/                            TypeScript unit tests.
```

See also:

- [`wallet/README.md`](wallet/README.md) for the TypeScript wallet module.
- [`scripts/README.md`](scripts/README.md) for the local end-to-end flow.

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

The E2E script starts Anvil with the Prague hardfork, deploys contracts, initializes the delegated account, executes normal and edge-case operations, performs recovery, and writes logs under `.e2e/`.

## Local E2E coverage

The current local end-to-end script validates:

- EIP-7702 delegation and initialization;
- successful execution through `executeSignedAndRotate`;
- auth signer rotation after each signed operation;
- local burning of consumed auth keys;
- target revert without global account revert;
- expired operation that rotates but skips external execution;
- invalid `nextAuthorizedSigner` causing `PAUSED`;
- signed recovery that installs a new auth signer and recovery signer;
- post-recovery execution.

## Current implementation status

Implemented:

- EIP-7702-oriented delegated account contract;
- one-time authorized signer rotation;
- pause-on-invalid-next-signer behavior;
- one-time recovery signer consumption and renewal;
- Foundry deployment scripts for implementation, delegated initialization, and execution target;
- Foundry tests for the account behavior;
- TypeScript deterministic auth/recovery key derivation;
- EIP-712 signing for operations and recovery operations;
- local wallet state machine with burned-key tracking;
- pure local/on-chain state reconciliation logic;
- viem-based account client for reads, transaction sending, and post-transaction sync;
- CLI scripts for local initialization, sync, execution, edge cases, and recovery;
- automated local E2E script.

Not implemented or not production-ready:

- secure key storage or hardware-backed signing;
- encrypted local state;
- browser extension, mobile app, or UI;
- multi-device coordination;
- production recovery UX;
- event indexing or persistent transaction history.

## Security notes

This project assumes a post-quantum-inspired threat model where an observed ECDSA signature may eventually expose the corresponding private key. The wallet therefore treats signing as the point of no return: once a signature is produced, the signing key is burned locally even if the transaction is not mined or the external action fails.

The smart contract and wallet are experimental and should not be used to secure real assets without further review, testing, and threat modeling.
