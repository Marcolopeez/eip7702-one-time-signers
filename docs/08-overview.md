# Project Overview

## Status

One-Time Signer Account / Wallet is an experimental research prototype.

It is not audited, not production-ready, and must not be used with real assets, production mnemonics, production RPC endpoints, or accounts that hold value.

The project explores an EIP-7702 account design where ECDSA authorization keys are treated as one-time-use keys under a narrow CRQC-oriented threat model.

## Problem

Ethereum accounts and many wallet flows rely on long-lived ECDSA keys.

This project explores a stricter assumption: once a valid ECDSA signature from a key has been observed, a CRQC-capable adversary may eventually recover or otherwise compromise that key.

Under this assumption, a signature is not just an authorization artifact. It is also treated as key exposure.

That means a key that has signed must not remain valid after the signature exists outside the wallet, even if:

* the transaction is dropped;
* the target call reverts;
* the operation expires;
* a relayer submits it later;
* the wallet or RPC provider reports an ambiguous result.

## Goal

The project studies whether an EOA can behave like a minimal smart account that rotates its ECDSA signer after every authorization.

The main security objective is:

> An authorized ECDSA key must not remain valid after a valid signature from that key has been observed.

The prototype implements this across two cooperating layers:

* a Solidity account that rotates or pauses after valid authorization;
* a TypeScript wallet that burns local keys immediately after signing and reconciles against on-chain storage.

This is not full post-quantum security. The account still uses ECDSA. The goal is narrower: reduce the window in which an observed ECDSA signature remains useful.

## Core idea

A one-time signer is an ECDSA keypair intended to authorize exactly one account operation.

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

After the account verifies a valid signature from `auth[i]`, that signer is considered exposed.

The contract therefore attempts to rotate to `auth[i+1]` before validating the executable part of the operation and before calling the target contract.

If rotation cannot safely install the next signer, the account enters paused mode. In paused mode, normal execution is blocked and recovery is required.

Recovery uses the same principle: recovery signers are also one-time keys.

## How EIP-7702 fits

`src/OneTimeSignerAccount.sol` is designed to be deployed once as implementation code and then used by an EOA through EIP-7702 delegation.

In the delegated execution context:

```text
address(this) = delegated EOA
storage       = delegated EOA storage
code          = implementation code
```

This matters for both state and signatures.

The account state belongs to the delegated EOA, not to the implementation contract. The EIP-712 domain must also bind signatures to the delegated EOA:

```text
verifyingContract = address(this)
```

Under EIP-7702, `address(this)` is the delegated EOA. This prevents signatures for one delegated EOA from being treated as valid for another EOA using the same implementation code.

The implementation includes protection against direct use of the implementation contract.

Implementation note: the account contract does not protect against compromise of the EIP-7702 authority key that controls delegation at the protocol level.

## Main components

### Solidity account

`src/OneTimeSignerAccount.sol` implements the on-chain account state machine.

It is responsible for:

* initializing delegated EOA storage;
* tracking `currentAuthorizedSigner`;
* tracking consumed or reserved signer addresses;
* tracking active recovery signers;
* verifying EIP-712 operation signatures;
* rotating the authorized signer before external calls;
* pausing when a valid signature is observed but rotation cannot safely continue;
* recovering the account with one-time recovery signers.

Normal signed execution uses `executeSignedAndRotate()`.

Recovery through relayed EIP-712 signatures uses `signedRecovery()`.

The contract stores signer addresses only. The corresponding private keys are derived and managed off-chain by the wallet.

### TypeScript wallet

The TypeScript wallet under `wallet/` manages the off-chain side of the protocol.

It is responsible for:

* deriving deterministic authorization and recovery signer streams;
* building and signing EIP-712 operations;
* selecting fresh next signers;
* persisting local key-consumption state immediately after signing;
* broadcasting signed operations through a relayer account;
* reading delegated-account storage;
* reconciling local state through `sync()`.

The critical wallet-side rule is:

```text
sign -> burn locally -> persist -> broadcast
```

The wallet must not wait for a receipt before marking a signer as consumed locally. Once a signature exists, the corresponding key is considered unsafe.

After a transaction, the final source of truth is on-chain storage read through `sync()`, not the receipt.

### CLI

The CLI commands are developer entrypoints for local testing and protocol exploration.

They cover initialization, synchronization, normal execution, failure scenarios, invalid-next-signer pause behavior, and recovery.

Main commands include:

```text
pnpm prepare:init
pnpm state:init
pnpm sync
pnpm execute:set-number
pnpm execute:target-revert
pnpm execute:expired-set-number
pnpm execute:invalid-next-auth
pnpm recover
```

The local end-to-end script runs these flows against Anvil:

```text
./scripts/run-local-e2e.sh
```

Some CLI flows are intentionally adversarial or dev-only. They exist to test contract behavior and must not be treated as production wallet flows.

### Browser extension

The browser extension is a WXT/React prototype around the same wallet SDK.

It exists to test how the one-time signer model behaves from a browser extension environment.

Current capabilities include:

* importing local wallet state;
* storing local development settings;
* syncing account state;
* executing the demo `ExecutionTarget.setNumber(uint256)` call;
* recovering a paused account;
* inspecting and exporting local wallet state.

The extension is not a generic Ethereum wallet. It does not implement an injected provider, dapp connection flow, arbitrary transaction signing, encrypted vault, unlock lifecycle, or production secret handling.

Use it only with local Anvil/test deployments.

## Goals and non-goals

### Goals

* Explore one-time ECDSA signer rotation for EIP-7702 delegated EOAs.
* Treat observed ECDSA signatures as key exposure under the assumed CRQC model.
* Ensure valid signatures do not leave the same signer in control.
* Rotate before external execution.
* Pause when safe rotation is impossible.
* Support recovery with one-time recovery signers.
* Keep wallet local state aligned with the on-chain account state.
* Provide Foundry, TypeScript, CLI, and browser-extension surfaces for experimentation.

### Non-goals

* Production wallet software.
* Full post-quantum security.
* Protection against compromise of the EIP-7702 authority key.
* Secure enclave, hardware-wallet, or encrypted key custody.
* Multi-device coordination.
* Generic dapp wallet compatibility.
* ERC-4337 integration.
* Arbitrary transaction UX.
* Social recovery UX.
* Formal verification.
* Use with real assets.

## Where to go next

* [`README.md`](../README.md): repository entry point and basic commands.
* [`docs/README.md`](./README.md): documentation index.
* [`docs/quickstart.md`](./quickstart.md): local setup and first run.
* [`docs/threat-model.md`](./threat-model.md): threat model, assumptions, and security invariants.
* [`docs/architecture.md`](./architecture.md): system architecture and trust boundaries.
* [`docs/contract.md`](./contract.md): Solidity account behavior.
* [`docs/wallet-architecture.md`](./wallet-architecture.md): TypeScript wallet internals.
* [`docs/cli.md`](./cli.md): CLI commands and local workflows.
* [`docs/browser-wallet.md`](./browser-wallet.md): browser extension prototype.
* [`docs/testing.md`](./testing.md): Foundry, Vitest, and local E2E validation.
