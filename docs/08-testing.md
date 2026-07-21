# Testing

This project is tested across the contract, wallet protocol logic, SDK state flow, browser extension build surface, and a local EIP-7702 end-to-end scenario.

The tests are part of the security model. For this prototype, a valid observed ECDSA signature is treated as key exposure, so tests should focus on whether signer consumption, rotation, pausing, recovery, and wallet reconciliation behave safely under failure.

This project is experimental. Passing tests does not make it production-ready or safe for real assets.

## Test layers

| Layer                     | Command                      | Location        | Responsibility                                                                                                                 |
| ------------------------- | ---------------------------- | --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Solidity / Foundry tests  | `forge test`                 | repository root | Contract-level account behavior, EIP-7702 delegated execution, signer rotation, pausing, recovery, EIP-712 binding             |
| TypeScript / Vitest tests | `pnpm test`                  | `wallet/`       | Wallet protocol logic, EIP-712 client-side hashing/signing, derivation, local state transitions, sync reconciliation, SDK flow |
| Wallet type checking      | `pnpm typecheck`             | `wallet/`       | Type safety for wallet source and tests under `wallet/src` and `wallet/test`                                                   |
| Extension type checking   | `pnpm typecheck:extension`   | `wallet/`       | Type safety for WXT/React extension entrypoints and extension-specific config                                                  |
| Extension build           | `pnpm extension:build`       | `wallet/`       | Verifies that the browser extension can be built by WXT                                                                        |
| Local e2e script          | `./scripts/run-local-e2e.sh` | repository root | Full local flow against a fresh Prague Anvil chain                                                                             |

There is no CI configuration in the attached files. Treat these commands as the local validation checklist for this prototype.

## Solidity tests

Run from the repository root:

```bash
forge test
```

The Solidity tests live in:

```text
test/OneTimeSignerAccountTest.t.sol
test/mocks/ExecutionTarget.sol
```

These tests validate the on-chain account behavior of `src/OneTimeSignerAccount.sol`.

They are responsible for:

* initialization through EIP-7702 delegation;
* separation between implementation storage and delegated EOA storage;
* protection against direct use of the implementation contract;
* direct authorized signer rotation;
* signed execution through `executeSignedAndRotate`;
* signer rotation before external target calls;
* preservation of rotation when target execution fails;
* paused-mode restrictions;
* direct recovery through active recovery signers;
* signed recovery through EIP-712 recovery operations;
* one-time use of authorized and recovery signers;
* EIP-712 domain binding to the delegated account.

Especially important tests include:

```text
test_initialize_setsFirstAuthorizedSignerAndRecoverySignersInDelegatedAccountStorage
test_initialize_revertsWhenCalledOnImplementation
test_rotateAuthorizedSigner_burnsPreviousSigner
test_rotateAuthorizedSigner_pausesWithZeroNextAuthorizedSigner
test_rotateAuthorizedSigner_pausesWhenReusingPreviousAuthorizedSigner
test_executeSignedAndRotate_allowsRelayerToSubmitOperationSignedByA2
test_executeSignedAndRotate_allowsNewKeyToContinueChain
test_executeSignedAndRotate_rotatesEvenWhenTargetReverts
test_executeSignedAndRotate_burnsA2SignatureAfterFailedExecution
test_executeSignedAndRotate_burnsA2SignatureAfterSuccessfulExecution
test_executeSignedAndRotate_pausesWhenNextAuthorizedSignerIsZero
test_executeSignedAndRotate_pausesWhenReusingAuthorizedSigner
test_executeSignedAndRotate_rotatesAndReturnsFailureWhenOperationExpired
test_executeSignedAndRotate_rotatesAndReturnsFailureWithZeroTarget
test_executeSignedAndRotate_rejectsSignatureBoundToAnotherDelegatedAccount
test_pausedAccount_revertsNormalSignedExecution
test_pausedAccount_revertsDirectAuthorizedRotation
test_rotateAuthorizedSignerThroughRecovery_unpausesPausedAccountAndRotatesRecoverySigner
test_rotateAuthorizedSignerThroughRecovery_cannotReuseConsumedRecoverySigner
test_rotateAuthorizedSignerThroughRecovery_newRecoverySignerCanRecoverAgain
test_signedRecovery_unpausesPausedAccountAndRotatesRecoverySigner
test_signedRecovery_consumesRecoverySignerWhenOperationExpired
test_signedRecovery_consumesRecoverySignerEvenWhenNextSignerIsInvalid
test_signedRecovery_replayFailsBecauseRecoverySignerWasConsumed
test_signedRecovery_rejectsSignatureBoundToAnotherDelegatedAccount
```

Run `forge test` whenever you touch:

* `src/OneTimeSignerAccount.sol`;
* contract storage layout;
* signer validation logic;
* `Operation` or `RecoveryOperation`;
* EIP-712 hashing or domain logic;
* pause or recovery behavior;
* deployment or initialization scripts that affect delegated account setup;
* tests or mocks under `test/`.

Also run it before relying on wallet-side protocol changes that must remain compatible with the contract.

## Wallet tests

Run from `wallet/`:

```bash
pnpm test
```

The wallet tests use Vitest and cover TypeScript protocol logic. They do not replace the Foundry tests; they validate the off-chain logic that prepares signatures, tracks local state, and reconciles with on-chain storage.

Main test files:

```text
wallet/test/crypto/derivation.test.ts
wallet/test/protocol/eip712.test.ts
wallet/test/protocol/state.test.ts
wallet/test/protocol/sync.test.ts
wallet/test/sdk/OneTimeSignerWallet.test.ts
```

### `derivation.test.ts`

Covers deterministic one-time signer derivation.

It checks that:

* auth signers are deterministic for the same context and index;
* auth indices produce different keys;
* auth and recovery streams are separated;
* recovery indices produce different keys;
* auth derivation changes across wallet IDs;
* recovery derivation currently does not change across wallet IDs;
* delegated account and chain ID affect auth derivation;
* invalid derivation indices are rejected.

Implementation note: the current tests explicitly assert that changing `walletId` does not change the recovery stream. Preserve or update this test intentionally if the derivation design changes.

### `eip712.test.ts`

Covers wallet-side EIP-712 construction.

It checks that:

* the domain uses `name = "OneTimeSignerAccount"`;
* the domain uses `version = "1"`;
* `verifyingContract` is the delegated account;
* `Operation.data` is represented as `dataHash`;
* operation signatures recover the expected auth signer;
* recovery operation signatures recover the expected recovery signer;
* operation digests change when `nextAuthorizedSigner`, calldata, chain ID, or delegated account changes;
* recovery digests change when `nextAuthorizedSigner` or `nextRecoverySigner` changes.

These tests are important because the contract expects signatures to be bound to the delegated EOA, not to the implementation contract.

### `state.test.ts`

Covers the local wallet state machine.

It checks that:

* initial state starts as `READY`;
* signing an operation immediately moves state to `PENDING_OPERATION`;
* the consumed auth index is recorded before broadcast;
* a second operation cannot be signed while an operation is pending;
* successful reconciliation advances to the next auth signer;
* failed rotation can resolve to `PAUSED`;
* transaction hashes can be attached to pending operations;
* recovery cannot be signed while `READY`;
* signing recovery immediately moves state to `PENDING_RECOVERY`;
* the consumed recovery index is recorded before broadcast;
* successful recovery returns to `READY`;
* failed recovery can remain `PAUSED`;
* JSON state can be saved and loaded.

These tests are critical for the wallet-side invariant that local state must be persisted immediately after signing and before transaction broadcast.

### `sync.test.ts`

Covers reconciliation between local state and on-chain storage.

It checks that:

* `READY` remains unchanged when on-chain state matches;
* `READY` moves to `PAUSED` if the chain is paused;
* `READY` throws if the local signer differs from the on-chain signer;
* `PENDING_OPERATION` remains pending if the chain has not advanced;
* `PENDING_OPERATION` moves to `READY` when the on-chain signer advances;
* `PENDING_OPERATION` moves to `PAUSED` when the account pauses;
* `PAUSED` remains paused while the chain is paused;
* `PENDING_RECOVERY` remains pending while recovery has not landed;
* `PENDING_RECOVERY` moves to `PAUSED` when the recovery key was consumed but recovery failed;
* `PENDING_RECOVERY` moves to `READY` when recovery fully succeeds;
* critical partial recovery throws;
* uninitialized on-chain accounts throw.

These tests are the main guardrail for the rule that the receipt is not the final source of truth. The wallet must reconcile against on-chain storage before considering itself safe to continue.

### `OneTimeSignerWallet.test.ts`

Covers the SDK-level flow using a fake account client.

It checks that:

* `execute()` signs an operation, persists a pending state, submits it, waits for a receipt, then syncs;
* execution is refused while the local state is `PAUSED`;
* `recover()` signs recovery, persists pending recovery, submits it, waits for a receipt, then syncs;
* recovery rotates both auth and recovery streams in the local state.

This test is especially important for validating call ordering: sign, persist pending state, submit transaction, wait, sync from chain.

Run `pnpm test` whenever you touch:

* `wallet/src/protocol/one-time-signer-account/*`;
* `wallet/src/sdk/*`;
* signer derivation;
* EIP-712 signing or hashing;
* local state transitions;
* sync/reconciliation logic;
* storage adapters;
* CLI commands that depend on wallet protocol state.

## Type checking

Run from `wallet/`:

```bash
pnpm typecheck
```

This runs:

```bash
tsc --noEmit -p tsconfig.json
```

It type checks:

```text
wallet/src
wallet/test
```

It excludes extension entrypoints, WXT output, build output, and `node_modules`.

Run `pnpm typecheck` whenever you touch TypeScript under:

```text
wallet/src
wallet/test
```

Also run it before treating wallet changes as locally validated, even if the Vitest tests pass.

## Browser extension build checks

Run from `wallet/`:

```bash
pnpm typecheck:extension
```

This runs:

```bash
wxt prepare && tsc --noEmit -p tsconfig.extension.json
```

It type checks:

```text
wallet/src
wallet/entrypoints
wallet/wxt.config.ts
```

Run it whenever you touch:

* extension entrypoints;
* popup UI;
* options UI;
* background logic;
* extension messaging types;
* browser storage integration;
* WXT config;
* shared wallet code used by the extension.

Also run the extension build from `wallet/`:

```bash
pnpm extension:build
```

This verifies that WXT can build the extension package.

Run `pnpm extension:build` whenever you touch:

* `wallet/entrypoints/*`;
* `wallet/src/apps/extension/*`;
* `wallet/wxt.config.ts`;
* extension assets or manifest-related settings;
* shared wallet code that is imported by the extension.

Implementation note: `pnpm typecheck:extension` validates TypeScript compatibility with the extension project. `pnpm extension:build` validates the bundling/build path. Use both for extension changes.

## Local e2e script

Run from the repository root:

```bash
./scripts/run-local-e2e.sh
```

The script starts a fresh local Anvil chain with the Prague hardfork enabled, because the flow depends on EIP-7702 delegation.

It performs a complete local scenario:

1. cleans previous wallet local state;
2. starts Anvil with Prague;
3. runs `forge build`;
4. installs wallet dependencies;
5. runs wallet type checking;
6. runs wallet tests;
7. deploys the implementation;
8. prepares wallet initialization data;
9. funds the delegated account and relayer;
10. attaches EIP-7702 delegation and initializes the delegated account;
11. deploys `ExecutionTarget`;
12. creates initial local wallet state;
13. syncs wallet state from chain;
14. executes `setNumber(111)`;
15. executes a target call that reverts;
16. executes an expired operation;
17. executes a dev-only invalid next signer operation that pauses the account;
18. runs signed recovery;
19. executes again after recovery.

The script validates that:

* EIP-7702 delegation and initialization work locally;
* successful execution rotates the auth signer;
* target revert does not revert the global account flow;
* expired operation rotates the signer but skips target effects;
* invalid `nextAuthorizedSigner` pauses the account;
* `signedRecovery` restores the wallet to `READY`;
* post-recovery execution works.

Logs are written to:

```text
.e2e/
```

Run `./scripts/run-local-e2e.sh` before treating changes as safe when they affect the integrated flow between contracts, scripts, wallet protocol logic, CLI commands, or local storage.

Also run it after coordinated changes across Solidity and TypeScript, even if `forge test` and `pnpm test` pass independently.

## Security invariant coverage

| Invariant                                                                                                 | Current coverage                                                                                                                                                                                                                                                          |
| --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| An ECDSA key that has signed must not control the account again.                                          | Covered by Foundry tests for direct rotation, signed execution replay after success/failure, and recovery signer replay. Covered wallet-side by local state tests that burn auth/recovery indices immediately after signing.                                              |
| No failure after a valid signature must revert the already-applied rotation.                              | Covered by Foundry tests for target revert, expired operations, and zero target after valid authorization. Covered e2e by target revert and expired operation flows.                                                                                                      |
| If the account cannot rotate to a valid key, it must enter paused mode.                                   | Covered by Foundry tests for zero/reused next authorized signers in direct and signed rotation. Covered e2e by the invalid next signer flow.                                                                                                                              |
| In paused mode, only recovery must be able to restore the account.                                        | Covered by Foundry tests that reject normal signed execution and direct authorized rotation while paused, plus recovery tests that unpause. ETH receive while paused is also tested.                                                                                      |
| Recovery keys are also one-time keys.                                                                     | Covered by Foundry direct recovery and signed recovery tests that consume recovery signers, reject reuse, and allow newly registered recovery signers to recover again. Covered wallet-side by recovery state tests that burn recovery indices immediately after signing. |
| Any observed signature is equivalent to key exposure in the CRQC threat model.                            | Represented by tests that consume auth and recovery signers after valid signatures, including failure paths. The tests validate the implementation policy, not the cryptographic CRQC assumption itself.                                                                  |
| EIP-712 `verifyingContract` must be the delegated EOA, not the implementation contract.                   | Covered by TypeScript EIP-712 domain tests and digest-change tests. Covered on-chain by Foundry tests rejecting signatures bound to another delegated account.                                                                                                            |
| The wallet must persist local state immediately after signing and before broadcast.                       | Covered by `state.test.ts` and SDK tests that assert pending state exists before final sync. This is unit-level coverage; crash recovery across process termination should be treated carefully when changing storage behavior.                                           |
| The final source of truth after a transaction is on-chain storage read through `sync()`, not the receipt. | Covered by sync reconciliation tests and SDK tests that perform final sync after receipt. The e2e script also reads on-chain storage after each important step.                                                                                                           |
| If local state and on-chain state cannot be safely reconciled, the wallet must refuse to sign.            | Partially covered by sync tests that throw on signer mismatch, uninitialized account, and critical partial recovery. SDK tests cover refusing execution while paused. Add targeted tests for any new ambiguous reconciliation state.                                      |

## When to run what

### Contract-only change

Run:

```bash
forge test
```

Also run the local e2e script if the change affects initialization, EIP-712 structs, rotation, pausing, recovery, or any externally visible contract behavior used by the wallet:

```bash
./scripts/run-local-e2e.sh
```

### Wallet protocol change

Run from `wallet/`:

```bash
pnpm test
pnpm typecheck
```

Also run `forge test` if the change must remain compatible with the contract, especially for EIP-712, signer selection, recovery, or sync assumptions.

### Extension change

Run from `wallet/`:

```bash
pnpm typecheck:extension
pnpm extension:build
```

If the extension change touches shared wallet protocol code, also run:

```bash
pnpm test
pnpm typecheck
```

### CLI or local e2e flow change

Run from `wallet/`:

```bash
pnpm test
pnpm typecheck
```

Then run from the repository root:

```bash
./scripts/run-local-e2e.sh
```

### Before relying on security-sensitive changes

Run the full local checklist:

```bash
forge test
./scripts/run-local-e2e.sh
```

And from `wallet/`:

```bash
pnpm test
pnpm typecheck
pnpm typecheck:extension
pnpm extension:build
```

## Adding new tests

When touching protocol logic, add tests at the layer where the invariant is enforced.

Use this rule of thumb:

| Change area                                                   | Add or update tests in                                                                                    |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Contract state, storage, modifiers, events, signer validation | `test/OneTimeSignerAccountTest.t.sol`                                                                     |
| EIP-712 typed data construction                               | `wallet/test/protocol/eip712.test.ts` and Foundry EIP-712 compatibility tests if contract hashing changes |
| Signer derivation                                             | `wallet/test/crypto/derivation.test.ts`                                                                   |
| Local state transitions                                       | `wallet/test/protocol/state.test.ts`                                                                      |
| On-chain/local reconciliation                                 | `wallet/test/protocol/sync.test.ts`                                                                       |
| High-level wallet execution/recovery flow                     | `wallet/test/sdk/OneTimeSignerWallet.test.ts`                                                             |
| CLI or local integration flow                                 | `scripts/run-local-e2e.sh` plus lower-level unit tests                                                    |

For new protocol behavior, test at least:

1. the happy path;
2. the failure path after a valid signature has been observed;
3. whether the signer is consumed or reserved;
4. whether the account should remain `READY`, become `PAUSED`, or enter recovery;
5. how local wallet state is persisted before broadcast;
6. how `sync()` reconciles the final on-chain state.

When adding a test for a bug, assert the security invariant directly. Avoid tests that only check that a function returns without throwing.

Good test names should make the invariant visible, for example:

```text
test_executeSignedAndRotate_rotatesEvenWhenTargetReverts
test_signedRecovery_replayFailsBecauseRecoverySignerWasConsumed
```

## Known gaps

* The attached files do not include CI configuration.
* The test suite does not prove production safety.
* The CRQC threat assumption is modeled as a signer-consumption policy; the tests do not validate cryptographic breakability.
* Wallet persistence is tested at the local state and JSON store level, but crash consistency across browser/runtime interruption should be reviewed carefully when storage behavior changes.
* Browser extension checks cover type checking and buildability. They do not appear to include browser automation or UI interaction tests.
* The e2e script uses deterministic local Anvil development keys and must not be used with real assets.
* Recovery and reconciliation have targeted tests for critical states, but any new partial-recovery or ambiguous sync state should get explicit tests before being relied on.


## Where to go next

* [`../README.md`](../README.md): repository entry point and basic commands.
* [`README.md`](./README.md): documentation index.
* [`00-quickstart.md`](./00-quickstart.md): local setup and first run.
* [`01-overview.md`](01-overview.md): conceptual entry point. 
* [`02-threat-model.md`](./02-threat-model.md): threat model, assumptions, and security invariants.
* [`03-architecture.md`](./03-architecture.md): system architecture and trust boundaries.
* [`04-contract.md`](./04-contract.md): Solidity account behavior.
* [`05-wallet-architecture.md`](./05-wallet-architecture.md): TypeScript wallet internals.
* [`06-cli.md`](./06-cli.md): CLI commands and local workflows.
* [`07-browser-wallet.md`](./07-browser-wallet.md): browser extension prototype.
* :pushpin: **[`08-testing.md`](./08-testing.md): Foundry, Vitest, and local E2E validation.**