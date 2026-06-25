# Documentation

This is the main documentation index for the One-Time Signer Account / Wallet research prototype.

The project explores an EIP-7702 delegated account model using one-time ECDSA signer keys under a partial post-quantum threat model.

> Experimental prototype only. Not audited. Not production-ready. Do not use with real assets.

## Start here

* [`../README.md`](../README.md): repository overview, layout, lifecycle summary, and current implementation status.
* [`08-overview.md`](08-overview.md): short project overview and conceptual entry point.
* [`06-quickstart.md`](06-quickstart.md): minimal setup path for running tests, checks, local E2E, and extension builds.
* [`00-threat-model.md`](00-threat-model.md): core assumptions, attacker model, invariants, and out-of-scope areas.

## Recommended reading paths

### New technical contributors

1. [`08-overview.md`](08-overview.md)
2. [`06-quickstart.md`](06-quickstart.md)
3. [`07-architecture.md`](07-architecture.md)
4. [`00-threat-model.md`](00-threat-model.md)
5. [`03-testing.md`](03-testing.md)

### Solidity contributors

1. [`00-threat-model.md`](00-threat-model.md)
2. [`07-architecture.md`](07-architecture.md)
3. [`01-contract.md`](01-contract.md)
4. [`03-testing.md`](03-testing.md)
5. [`../SECURITY.md`](../SECURITY.md)

### TypeScript wallet contributors

1. [`08-overview.md`](08-overview.md)
2. [`02-wallet-architecture.md`](02-wallet-architecture.md)
3. [`04-cli.md`](04-cli.md)
4. [`05-browser-wallet.md`](05-browser-wallet.md)
5. [`03-testing.md`](03-testing.md)

### Security reviewers

1. [`../SECURITY.md`](../SECURITY.md)
2. [`00-threat-model.md`](00-threat-model.md)
3. [`01-contract.md`](01-contract.md)
4. [`02-wallet-architecture.md`](02-wallet-architecture.md)
5. [`03-testing.md`](03-testing.md)

## Core concepts

* [`08-overview.md`](08-overview.md): problem, goal, components, and non-goals.
* [`00-threat-model.md`](00-threat-model.md): CRQC assumption, one-time signer model, recovery model, and critical invariants.
* [`01-contract.md`](01-contract.md): delegated account behavior, storage model, EIP-712 domain, signer rotation, pausing, and recovery.
* [`02-wallet-architecture.md`](02-wallet-architecture.md): local state, signer derivation, signing lifecycle, sync, reconciliation, and storage adapters.

## Architecture

* [`07-architecture.md`](07-architecture.md): system architecture, trust boundaries, component roles, and lifecycle diagrams.
* [`01-contract.md`](01-contract.md): Solidity account architecture.
* [`02-wallet-architecture.md`](02-wallet-architecture.md): TypeScript wallet architecture.
* [`05-browser-wallet.md`](05-browser-wallet.md): experimental browser extension structure and limitations.
* [`../wallet/README.md`](../wallet/README.md): wallet package overview, when present in the repository.

## Usage

* [`06-quickstart.md`](06-quickstart.md): fastest path to run the prototype locally.
* [`04-cli.md`](04-cli.md): CLI flows for initialization, sync, execution, failure scenarios, and recovery.
* [`05-browser-wallet.md`](05-browser-wallet.md): browser extension development and prototype usage.
* [`../scripts/README.md`](../scripts/README.md): local E2E script workflow, when present in the repository.

## Development and testing

* [`03-testing.md`](03-testing.md): Solidity tests, wallet tests, type checks, extension checks, local E2E coverage, and known gaps.
* [`06-quickstart.md`](06-quickstart.md): setup and basic verification path.
* [`04-cli.md`](04-cli.md): CLI commands used by development and local testing flows.
* [`05-browser-wallet.md`](05-browser-wallet.md): extension development, build checks, storage notes, and security caveats.

## Security

* [`../SECURITY.md`](../SECURITY.md): security policy, supported status, disclosure guidance, and in-scope areas.
* [`00-threat-model.md`](00-threat-model.md): detailed threat model and security invariants.
* [`01-contract.md`](01-contract.md): contract-level security properties and known limitations.
* [`02-wallet-architecture.md`](02-wallet-architecture.md): wallet-side signing, persistence, sync, and refusal rules.
* [`03-testing.md`](03-testing.md): security invariant coverage and testing gaps.
