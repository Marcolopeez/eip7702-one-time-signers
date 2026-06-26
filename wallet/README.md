# Wallet Package

## Status

This package is part of the **One-Time Signer Account / One-Time Signer Wallet** experimental research prototype.

It is **not audited**, **not production-ready**, and **must not be used with real assets, real mnemonics, or production keys**.

The browser extension is also experimental. It is a local development interface for testing the wallet flow, not a production wallet.

## Purpose

The `wallet/` package contains the TypeScript implementation used to operate a delegated `OneTimeSignerAccount` locally.

It provides:

* protocol logic for one-time signer operations;
* SDK orchestration for signing, local state updates, broadcasting, and sync;
* deterministic auth and recovery signer derivation;
* storage and viem adapters;
* local CLI commands;
* an experimental WXT/React browser extension;
* TypeScript ABI files used by the wallet.

The wallet exists to support development and testing of the one-time signer account model. It is not a general-purpose Ethereum wallet.

## Package layout

```text
wallet/
├── entrypoints/                 # WXT extension entrypoints
├── src/
│   ├── adapters/                # Storage and viem adapters
│   ├── apps/
│   │   ├── cli/                 # Local development CLI commands
│   │   └── extension/           # Experimental browser-extension app
│   ├── contracts/               # Contract ABI files
│   ├── crypto/                  # Deterministic signer derivation and hex helpers
│   ├── protocol/                # Pure One-Time Signer Account protocol logic
│   └── sdk/                     # High-level wallet orchestration
├── test/                        # Vitest test suite
├── package.json
├── tsconfig.json
├── tsconfig.extension.json
└── wxt.config.ts
```

Main internal areas:

* `src/protocol/one-time-signer-account/`: EIP-712 builders, signer selection, local state transitions, and sync reconciliation logic.
* `src/sdk/`: `OneTimeSignerWallet`, the main API used by the CLI and extension.
* `src/crypto/`: deterministic derivation for auth and recovery signer streams.
* `src/adapters/`: JSON/browser storage adapters and the viem account client.
* `src/apps/cli/`: local commands for initialization, execution, sync, recovery, and dev flows.
* `src/apps/extension/`: experimental WXT/React browser-extension implementation.
* `src/contracts/`: generated or maintained ABI files used by the wallet.

## Common commands

Run these commands from `wallet/`.

```bash
pnpm typecheck
```

Type-check the core TypeScript package.

```bash
pnpm typecheck:extension
```

Prepare WXT and type-check the browser-extension project.

```bash
pnpm test
```

Run the Vitest test suite.

```bash
pnpm extension:build
```

Build the experimental browser extension.

```bash
pnpm extension:dev
```

Run the experimental browser extension in WXT development mode.

## Documentation

* [Wallet architecture](../docs/05-wallet-architecture.md)
* [CLI](../docs/06-cli.md)
* [Browser wallet](../docs/07-browser-wallet.md)
* [Testing](../docs/08-testing.md)
* [Quickstart](../docs/00-quickstart.md)
