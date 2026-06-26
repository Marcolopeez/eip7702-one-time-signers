# Quickstart

## Status

This is an experimental research prototype.

It is **not audited**, **not production-ready**, and **must not be used with real assets**. All local keys, mnemonics, accounts, and flows used by this repository are for development and testing only.

## Prerequisites

Install:

* [Foundry](https://book.getfoundry.sh/) — `forge`, `cast`, `anvil`
* Node.js
* `pnpm`
* A Chromium-based browser or another browser suitable for WXT extension development, if working on the browser extension

## Install dependencies

From the repository root:

```bash
git submodule update --init --recursive
```

Install wallet dependencies from `wallet/`:

```bash
cd wallet
pnpm install
cd ..
```

## Run contract tests

From the repository root:

```bash
forge test
```

## Run wallet checks

From `wallet/`:

```bash
pnpm typecheck
pnpm typecheck:extension
pnpm test
```

## Run local e2e

From the repository root:

```bash
./scripts/run-local-e2e.sh
```

This runs the local end-to-end development flow, including contract deployment, EIP-7702 delegation setup, wallet operations, failure cases, pause, recovery, and post-recovery execution.

## Build or run the browser extension

From `wallet/`:

```bash
pnpm extension:build
```

For WXT development mode:

```bash
pnpm extension:dev
```

The browser extension is part of the experimental prototype and is intended for local development only.

## Next steps

* [`docs/01-overview.md`](01-overview.md)
* [`docs/02-threat-model.md`](02-threat-model.md)
* [`docs/03-architecture.md`](03-architecture.md)
* [`docs/04-contract.md`](04-contract.md)
* [`docs/05-wallet-architecture.md`](05-wallet-architecture.md)
* [`docs/06-cli.md`](06-cli.md)
* [`docs/07-browser-wallet.md`](07-browser-wallet.md)
* [`docs/08-testing.md`](08-testing.md)
