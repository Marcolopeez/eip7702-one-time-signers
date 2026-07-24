# Documentation

This is the main documentation index for the One-Time Signer Account / Wallet research prototype.

The project explores an EIP-7702 delegated account model using one-time ECDSA signer keys under a post-quantum threat model.

> Experimental prototype only. Not audited. Not production-ready. Do not use with real assets.

## Start here

* [`../README.md`](../README.md): repository overview, layout, status, and main links.
* :pushpin: **[`README.md`](./README.md): documentation index**.
* [`00-quickstart.md`](./00-quickstart.md): local setup and first run.
* [`01-overview.md`](01-overview.md): conceptual entry point. 
* [`02-threat-model.md`](./02-threat-model.md): threat model, assumptions, and security invariants.
* [`03-architecture.md`](./03-architecture.md): system architecture and trust boundaries.
* [`04-contract.md`](./04-contract.md): Solidity account behavior.
* [`05-wallet-architecture.md`](./05-wallet-architecture.md): TypeScript wallet internals, including key derivation.
* [`06-cli.md`](./06-cli.md): CLI commands and local workflows.
* [`07-browser-wallet.md`](./07-browser-wallet.md): browser extension prototype.
* [`08-testing.md`](./08-testing.md): Foundry, Vitest, and local E2E validation.