# One-Time Signer Account

> [!WARNING]
> **Experimental research prototype.**
>
> This project is not audited, not production-ready, and must not be used with real assets, production mnemonics, production RPC endpoints, or accounts that hold value.

## Status

One-Time Signer Account is an experimental Ethereum account and wallet prototype based on:

* EIP-7702 delegated EOA execution;
* EIP-712 signed operations;
* one-time ECDSA authorization keys;
* one-time ECDSA recovery keys;
* a TypeScript wallet that mirrors the account’s key-consumption rules.

The project studies a narrow partial post-quantum threat model: if a CRQC-capable adversary observes a valid ECDSA signature, the corresponding ECDSA key must be treated as exposed.

This is not full post-quantum security. The system still uses ECDSA.

## What this project explores

Ethereum wallets commonly rely on long-lived ECDSA keys. This project explores a stricter design rule:

> An ECDSA key that has produced a valid signature must not remain able to control the account.

The prototype asks whether an EOA, using EIP-7702 delegation, can behave like a minimal smart account that rotates its authorized signer after every valid authorization.

The main security objective is to reduce the window in which an observed ECDSA signature remains useful.

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

The contract therefore attempts to rotate to `auth[i+1]` before validating the executable part of the operation and before calling the external target.

If the account cannot rotate to a valid next signer, it enters paused mode. In paused mode, normal execution is blocked and recovery is required.

Recovery uses the same principle: recovery signers are also one-time keys.

The wallet must follow the corresponding off-chain rule:

```text
sign -> burn locally -> persist -> broadcast
```

After a transaction, the final source of truth is on-chain account storage read through `sync()`, not the transaction receipt.

## How EIP-7702 fits

`src/OneTimeSignerAccount.sol` is designed to be deployed as reusable implementation code and used by an EOA through EIP-7702 delegation.

In the delegated execution context:

```text
address(this) = delegated EOA
storage       = delegated EOA storage
code          = implementation code
```

This matters for both state and signatures.

Account state is stored in the delegated EOA, not in the implementation contract. 

Implementation note: the account cannot protect against compromise of the EIP-7702 authority key that controls delegation at the protocol level.

For the full conceptual model, start with [`docs/01-overview.md`](docs/01-overview.md) and [`docs/02-threat-model.md`](docs/02-threat-model.md).

## Repository layout

```text
.
├── src/
│   └── OneTimeSignerAccount.sol          # Solidity delegated account implementation
├── test/
│   ├── OneTimeSignerAccountTest.t.sol    # Foundry account tests
│   └── mocks/ExecutionTarget.sol         # Local execution target
├── script/                               # Foundry deployment/init scripts
├── scripts/
│   └── run-local-e2e.sh                  # Local end-to-end flow
├── wallet/                               # TypeScript wallet, SDK, CLI, extension
│   ├── entrypoints/                      # WXT extension entrypoints
│   ├── src/
│   │   ├── adapters/                     # Storage and viem adapters
│   │   ├── apps/
│   │   │   ├── cli/                      # Local development CLI commands
│   │   │   └── extension/                # Experimental browser-extension app
│   │   ├── contracts/                    # Contract ABI files
│   │   ├── crypto/                       # Deterministic signer derivation and hex helpers
│   │   ├── protocol/                     # Protocol logic (EIP-712, state, signer selection, sync logic)
│   │   └── sdk/                          # High-level wallet orchestration
│   └── test/                             # Vitest tests
├── docs/                                 # Project documentation
├── SECURITY.md                           # Security policy
└── README.md
```

## Quickstart

For the full setup path, see [`docs/00-quickstart.md`](docs/00-quickstart.md).

Minimal local checks:

```bash
forge test
```

From `wallet/`:

```bash
pnpm install
pnpm typecheck
pnpm typecheck:extension
pnpm test
pnpm extension:build
```

Run the local end-to-end flow from the repository root:

```bash
./scripts/run-local-e2e.sh
```

This flow is intended for local development only. It uses local keys, local state, local contracts, and a local EIP-7702 test environment.

## Documentation

Start with [`docs/README.md`](docs/README.md).

Primary documents:

* [`docs/00-quickstart.md`](docs/00-quickstart.md) — local setup and first run
* [`docs/01-overview.md`](docs/01-overview.md) — conceptual entry point
* [`docs/02-threat-model.md`](docs/02-threat-model.md) — threat model, assumptions, and invariants
* [`docs/03-architecture.md`](docs/03-architecture.md) — system architecture and trust boundaries
* [`docs/04-contract.md`](docs/04-contract.md) — Solidity account behavior
* [`docs/05-wallet-architecture.md`](docs/05-wallet-architecture.md) — TypeScript wallet design
* [`docs/06-cli.md`](docs/06-cli.md) — local CLI flows
* [`docs/07-browser-wallet.md`](docs/07-browser-wallet.md) — experimental browser wallet
* [`docs/08-testing.md`](docs/08-testing.md) — test layers and validation checklist

Package-level maps:

* [`wallet/README.md`](wallet/README.md) — wallet package overview
* [`scripts/README.md`](scripts/README.md) — local and Foundry scripts

## Security

Read [`SECURITY.md`](SECURITY.md) and [`docs/02-threat-model.md`](docs/02-threat-model.md) before relying on any account or wallet behavior.

Critical constraints:

* the project is experimental and unaudited;
* the account still uses ECDSA;
* the CRQC model is partial and does not provide full post-quantum security;
* local wallet state is security-critical because it records burned keys and pending signatures;
* the browser wallet is not a production wallet and does not provide production-grade secret storage;
* EIP-7702 delegation remains ultimately controlled by the original EOA authority key.

## Current implementation status

Implemented prototype components include:

* Solidity delegated account implementation;
* Foundry tests;
* Foundry deployment and initialization scripts;
* local EIP-7702 end-to-end script;
* TypeScript protocol layer;
* wallet SDK;
* JSON and browser storage adapters;
* viem client adapter;
* CLI commands for initialization, sync, execution, failure scenarios, and recovery;
* WXT/React browser extension prototype.

Known limitations include:

* no audit;
* no production hardening;
* no formal verification;
* no production-grade key custody;
* no encrypted browser wallet vault;
* no multi-device coordination;
* no production recovery UX;
* no support for real assets;
* EIP-7702 delegation remains ultimately controlled by the original EOA authority key; the prototype assumes a future mechanism such as EIP-7851 to disable that authority.

## License

TODO: add license information before publishing.