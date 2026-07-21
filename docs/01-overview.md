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

`src/OneTimeSignerAccount.sol` implements the delegated EOA account state machine. It owns the on-chain rules for initialization, signer rotation, pausing, EIP-712 validation, and recovery.

See [`04-contract.md`](./04-contract.md) for storage, function behavior, execution order, and contract-level invariants.

### TypeScript wallet

The TypeScript wallet under `wallet/` implements the off-chain side of the protocol: signer derivation, EIP-712 payload construction, local key burning, persistence, broadcasting, and sync.

The critical wallet-side rule is:

```text
sign -> burn locally -> persist -> broadcast
```

After a transaction, the final source of truth is on-chain storage read through `sync()`, not the receipt.

See [`05-wallet-architecture.md`](./05-wallet-architecture.md) for deterministic key derivation, the wallet state machine, SDK boundary, storage adapters, and reconciliation rules.

### CLI

The CLI is a local operational surface for initialization, sync, execution, failure scenarios, pause behavior, and recovery.

Some CLI flows are intentionally adversarial or dev-only. They exist to exercise contract behavior and must not be treated as production wallet flows.

See [`06-cli.md`](./06-cli.md) for commands and environment variables.

### Browser extension

The browser extension is a WXT/React prototype around the same wallet SDK. It exists to test the model from a browser-extension environment.

It is not a generic Ethereum wallet: it does not implement an injected provider, dapp connection flow, arbitrary transaction signing, encrypted vault, unlock lifecycle, or production secret handling.

See [`07-browser-wallet.md`](./07-browser-wallet.md) for capabilities, storage, UI, and limitations.

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

* [`../README.md`](../README.md): repository entry point and basic commands.
* [`README.md`](./README.md): documentation index.
* [`00-quickstart.md`](./00-quickstart.md): local setup and first run.
* :pushpin: **[`01-overview.md`](01-overview.md): conceptual entry point.** 
* [`02-threat-model.md`](./02-threat-model.md): threat model, assumptions, and security invariants.
* [`03-architecture.md`](./03-architecture.md): system architecture and trust boundaries.
* [`04-contract.md`](./04-contract.md): Solidity account behavior.
* [`05-wallet-architecture.md`](./05-wallet-architecture.md): TypeScript wallet internals, including key derivation.
* [`06-cli.md`](./06-cli.md): CLI commands and local workflows.
* [`07-browser-wallet.md`](./07-browser-wallet.md): browser extension prototype.
* [`08-testing.md`](./08-testing.md): Foundry, Vitest, and local E2E validation.
