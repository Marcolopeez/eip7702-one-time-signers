# CLI

## Status

The CLI is experimental development tooling for the One-Time Signer Wallet prototype.

It is intended for:

* local demos;
* protocol validation;
* testing wallet state transitions;
* exercising failure and recovery paths.

It is not production tooling. Do not use it with real assets, production accounts, or secrets that matter.

## Purpose

The CLI provides a thin operational layer over the wallet SDK. It lets contributors run the main account flows from the terminal without using the browser extension UI.

The CLI is useful for validating that the wallet preserves the protocol’s core safety property:

> Once a one-time ECDSA signer has produced an observable valid signature, that signer must never control the account again.

The CLI also makes it easier to inspect how local wallet state changes across:

* initialization;
* synchronization;
* normal execution;
* failed target execution;
* expired operations;
* invalid signer rotation;
* paused-account recovery.

## Requirements

Run CLI commands from `wallet/`:

```bash
cd wallet
```

Install dependencies first:

```bash
pnpm install
```

The CLI assumes a local or development chain is available and that the account contracts have been deployed and initialized using the repository’s Foundry scripts.

The CLI does not replace the root-level local demo flow. For the end-to-end setup, use the project quickstart or:

```bash
./scripts/run-local-e2e.sh
```

## Environment

Environment variables are parsed by `src/apps/cli/shared/env.ts` and `src/apps/cli/shared/walletFromEnv.ts`.

The scripts fail fast if required values are missing or malformed.

### Common variables

| Variable              |                                          Required | Default                 | Used by                          | Description                                                                                     |
| --------------------- | ------------------------------------------------: | ----------------------- | -------------------------------- | ----------------------------------------------------------------------------------------------- |
| `MNEMONIC`            |                                               Yes | —                       | wallet-backed commands           | BIP-39 mnemonic used to derive auth and recovery signers.                                       |
| `BIP39_PASSPHRASE`    |                                                No | `""`                    | wallet-backed commands           | Optional BIP-39 passphrase.                                                                     |
| `WALLET_ID`           | Yes for initialization and invalid-next-auth demo | —                       | init/dev flows                   | `0x`-prefixed wallet identifier included in deterministic derivation.                           |
| `RPC_URL`             |                                                No | `http://127.0.0.1:8545` | state, sync, execution, recovery | RPC endpoint for the development chain.                                                         |
| `STATE_IN`            |                                                No | `.local/state.json`     | sync, execution, recovery        | Local wallet state file to read.                                                                |
| `STATE_OUT`           |                                                No | `.local/state.json`     | `state:init`                     | Local wallet state file to write.                                                               |
| `RELAYER_PRIVATE_KEY` |                            Yes for write commands | —                       | execution and recovery           | Private key used only to submit transactions and pay gas. It is not an auth or recovery signer. |

### Initialization variables

| Variable                 | Required | Default            | Used by        | Description                                                         |
| ------------------------ | -------: | ------------------ | -------------- | ------------------------------------------------------------------- |
| `AUTHORITY_PRIVATE_KEY`  |      Yes | —                  | `prepare:init` | Private key of the EOA that becomes the delegated EIP-7702 account. |
| `IMPLEMENTATION_ADDRESS` |      Yes | —                  | `prepare:init` | Address of the deployed `OneTimeSignerAccount` implementation.      |
| `CHAIN_ID`               |       No | `31337`            | `prepare:init` | Chain ID included in derivation and EIP-712 context.                |
| `ACCOUNT_INDEX`          |       No | `0`                | `prepare:init` | Account index included in deterministic derivation.                 |
| `INIT_OUT`               |       No | `.local/init.json` | `prepare:init` | JSON initialization file consumed by `state:init`.                  |
| `INIT_ENV_OUT`           |       No | `.local/init.env`  | `prepare:init` | Shell env file for Foundry initialization scripts.                  |
| `INIT_IN`                |       No | `.local/init.json` | `state:init`   | Initialization file produced by `prepare:init`.                     |

### Operation variables

| Variable                   | Required | Default          | Used by                | Description                                                                             |
| -------------------------- | -------: | ---------------- | ---------------------- | --------------------------------------------------------------------------------------- |
| `EXECUTION_TARGET_ADDRESS` |      Yes | —                | execution demos        | Address of the local `ExecutionTarget` contract.                                        |
| `NEW_NUMBER`               |       No | command-specific | set-number demos       | Value passed to `ExecutionTarget.setNumber(uint256)`.                                   |
| `DEADLINE_SECONDS`         |       No | `3600`           | execution and recovery | Relative deadline for signed operations, unless the command intentionally overrides it. |
| `OPERATION_VALUE_ETH`      |       No | `0`              | `execute:set-number`   | ETH value sent with the operation.                                                      |
| `AUTH_LOOKAHEAD`           |       No | `50`             | `recover`              | Search window for the next unused auth signer.                                          |
| `RECOVERY_LOOKAHEAD`       |       No | `50`             | `recover`              | Search window for the next available recovery signer.                                   |

## Initialization flow

### 1. Prepare initialization data

```bash
pnpm prepare:init
```

This command derives the first auth and recovery signers for the delegated EOA.

It writes:

* `.local/init.json`, consumed by the wallet CLI;
* `.local/init.env`, intended for the Foundry initialization scripts.

The generated values include:

* delegated account address;
* implementation address;
* `auth[0]`;
* `recovery[0]`;
* chain ID;
* account index.

The delegated account is the EOA derived from `AUTHORITY_PRIVATE_KEY`.

### 2. Initialize the delegated account on-chain

Use the generated initialization values with the repository’s Foundry scripts.

This document does not duplicate the full deployment flow. The important requirement is that on-chain delegated-account storage must be initialized with the same first auth and recovery signers generated by `pnpm prepare:init`.

### 3. Create local wallet state

```bash
pnpm state:init
```

This command reads `.local/init.json`, derives the expected `auth[0]` and `recovery[0]` again, and refuses to continue if local derivation does not match the initialization file.

It then reads delegated-account storage through `sync()` and only writes `.local/state.json` if the on-chain account matches the expected initial `READY` state.

### 4. Sync after initialization

```bash
pnpm sync
```

This verifies that the persisted local state and delegated-account storage can still be reconciled.

## Normal operation

### Execute `setNumber`

```bash
pnpm execute:set-number
```

This command executes `ExecutionTarget.setNumber(uint256)` through the delegated account.

Default behavior:

* target: `EXECUTION_TARGET_ADDRESS`;
* number: `NEW_NUMBER`, default `42`;
* value: `OPERATION_VALUE_ETH`, default `0`;
* deadline: `DEADLINE_SECONDS`, default `3600`.

Internally, the SDK follows the security-critical sequence:

```text
sync -> derive current signer -> find next unused signer -> sign
-> burn current signer locally -> persist state -> broadcast
-> wait for receipt -> sync from on-chain storage -> persist reconciled state
```

The command requires `RELAYER_PRIVATE_KEY` because the relayer submits the transaction. The relayer is not the auth signer.

## Sync

```bash
pnpm sync
```

`sync` reconciles the local JSON state with delegated-account storage.

It does not:

* derive signers;
* produce signatures;
* send transactions.

It reads the local state file, queries the delegated account, applies the reconciliation rules, and saves the updated state if needed.

Use it whenever local state may be stale, especially after interrupted commands or manual contract interaction.

The receipt is not treated as the source of truth. The source of truth is delegated-account storage read during sync.

## Recovery

```bash
pnpm recover
```

Recovery is only valid when the local state reconciles to `PAUSED`.

The command:

* syncs first;
* verifies that the wallet is paused;
* derives the current recovery signer;
* checks that the current recovery signer is active on-chain;
* finds a fresh auth signer;
* finds a fresh recovery signer;
* signs a `RecoveryOperation`;
* burns the current recovery signer locally before broadcast;
* submits `signedRecovery`;
* syncs from on-chain storage after inclusion.

A successful recovery restores the account to `READY` with:

* a fresh current authorized signer;
* a fresh current recovery signer.

Recovery keys are one-time keys too.

## Failure and dev-only flows

These commands intentionally exercise edge cases. They are useful for validating security invariants, not for normal wallet usage.

### Target revert

```bash
pnpm execute:target-revert
```

Calls `ExecutionTarget.alwaysRevert()` through the account.

This demonstrates that a target-level revert does not globally revert the account operation. The signer rotation must survive even if the external call fails.

Expected behavior:

* transaction receipt status is `success`;
* sync reason is `PENDING_OPERATION_TO_READY`;
* wallet returns to `READY`;
* auth index advances.

### Expired operation

```bash
pnpm execute:expired-set-number
```

Creates a `setNumber` operation with an already-expired deadline.

This validates that failure after observing a valid signature does not revive the consumed signer.

Expected behavior:

* transaction receipt status is `success`;
* sync reason is `PENDING_OPERATION_TO_READY`;
* wallet returns to `READY`;
* auth index advances.

Default `NEW_NUMBER` for this command is `777`.

### Invalid next authorized signer

```bash
pnpm execute:invalid-next-auth
```

Dev-only adversarial flow.

This command intentionally signs an operation with an invalid `nextAuthorizedSigner` value: the zero address.

A production wallet must never sign this payload.

The script bypasses the normal safe state transition and uses an explicit unsafe dev-only transition to test the emergency pause path.

Expected behavior:

* transaction does not globally revert;
* account enters `PAUSED`;
* consumed auth key remains burned locally;
* normal execution is blocked until recovery;
* sync reason is `PENDING_OPERATION_TO_PAUSED`.

Default `NEW_NUMBER` for this command is `999`.

## Dev/demo commands

### Derivation demo

```bash
pnpm derive:demo
```

Prints deterministic auth and recovery signer addresses from a hardcoded test mnemonic.

This command does not read wallet state, connect to RPC, sign transactions, or use real secrets.

### Signing demo

```bash
pnpm sign:demo
```

Derives deterministic test signers, signs sample `Operation` and `RecoveryOperation` payloads, prints the EIP-712 digests and signatures, and recovers the signer addresses.

This command is only a local signing demonstration. It does not read wallet state or send transactions.

Implementation note: `package.json` maps this command to `src/apps/cli/commands/dev/sign-Demo.ts`. If the command fails on a case-sensitive filesystem, check that the package script path matches the actual filename.

### Package-level development scripts

The wallet package also exposes development scripts that are not account CLI flows:

```bash
pnpm test
pnpm test:watch
pnpm typecheck
pnpm typecheck:extension
pnpm typecheck:all
pnpm extension:dev
pnpm extension:build
pnpm extension:zip
```

Use these for tests, TypeScript checks, and browser extension development.

## How the CLI fits into the wallet architecture

The CLI is a thin wrapper around the same wallet components used by the rest of the prototype.

```mermaid
flowchart LR
    CLI[CLI command] --> SDK[OneTimeSignerWallet SDK]
    SDK --> Store[JsonWalletStateStore]
    SDK --> Client[OneTimeSignerAccountClient]
    Client --> RPC[RPC / viem]
    RPC --> Account[Delegated EIP-7702 account]
```

The main components are:

* CLI commands in `src/apps/cli/commands`;
* shared environment bootstrap in `src/apps/cli/shared`;
* `OneTimeSignerWallet` as the high-level SDK boundary;
* `JsonWalletStateStore` as local JSON-backed state storage;
* `OneTimeSignerAccountClient` as the viem-backed contract adapter;
* `OneTimeSignerAccount` as the delegated account logic executed at the EOA address.

The SDK owns the critical signing sequence. CLI commands should not call low-level signing helpers directly unless they are explicitly dev-only adversarial tests.

The viem adapter separates reads from writes:

* `sync()` only needs a public RPC client;
* execution and recovery require a relayer private key;
* auth and recovery signers never pay gas in these CLI flows.

EIP-712 signing uses the delegated account as the account context. Under EIP-7702, that means the delegated EOA address, not the implementation contract address.

## Safety notes

This CLI is not safe for production use.

Do not use it with:

* real assets;
* production EOAs;
* production mnemonics;
* valuable private keys;
* accounts that cannot tolerate state loss.

Local state is security-critical. The JSON state records burned one-time keys and pending signatures. Losing, editing, or rolling back this file can make the wallet unsafe.

A key must be considered burned locally as soon as it signs. The CLI persists local state after signing and before broadcast to preserve this invariant.

Do not sign if sync or reconciliation is unsafe. If local state and on-chain state cannot be reconciled, the wallet must refuse to continue.

Some commands intentionally exercise failure paths. In particular:

* `pnpm execute:target-revert`;
* `pnpm execute:expired-set-number`;
* `pnpm execute:invalid-next-auth`.

These commands may produce failed target calls, expired operations, paused accounts, or recovery-required states by design.
