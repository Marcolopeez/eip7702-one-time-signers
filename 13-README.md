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
* one-time recovery keys;
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

Account state is stored in the delegated EOA, not in the implementation contract. EIP-712 signatures are also bound to the delegated EOA:

```text
verifyingContract = address(this)
```

Under EIP-7702, `address(this)` is the delegated EOA. This prevents signatures for one delegated EOA from being valid for another EOA using the same implementation code.

The implementation includes protection against direct use of the implementation contract.

Implementation note: the account cannot protect against compromise of the EIP-7702 authority key that controls delegation at the protocol level.

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
│   ├── src/protocol/                     # EIP-712, state, signer selection, sync logic
│   ├── src/sdk/                          # Wallet orchestration layer
│   ├── src/adapters/                     # Storage and viem adapters
│   ├── src/apps/cli/                     # Development CLI commands
│   ├── src/apps/extension/               # Browser extension logic
│   └── test/                             # Vitest tests
├── docs/                                 # Project documentation
├── SECURITY.md                           # Security policy
└── README.md
```

## Quickstart

For the full setup path, see [`docs/quickstart.md`](docs/quickstart.md).

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

Start with the documentation index:

* [`docs/README.md`](docs/README.md) — documentation map and reading paths
* [`docs/quickstart.md`](docs/quickstart.md) — setup and local validation
* [`docs/overview.md`](docs/overview.md) — project overview and conceptual entry point
* [`docs/architecture.md`](docs/architecture.md) — system architecture and lifecycle
* [`docs/contract.md`](docs/contract.md) — Solidity account behavior
* [`docs/wallet-architecture.md`](docs/wallet-architecture.md) — TypeScript wallet design
* [`docs/cli.md`](docs/cli.md) — local CLI flows
* [`docs/browser-wallet.md`](docs/browser-wallet.md) — experimental browser extension
* [`docs/testing.md`](docs/testing.md) — test layers and coverage

## Security

Read [`SECURITY.md`](SECURITY.md) and [`docs/threat-model.md`](docs/threat-model.md) before modifying the account or wallet logic.

Critical security rules:

1. A signer that has produced a valid signature must not control the account again.
2. Rotation must happen before external calls.
3. Failures after valid signature verification must not resurrect the exposed signer.
4. If safe rotation is impossible, the account must pause.
5. In paused mode, only recovery can restore normal execution.
6. Recovery signers are also one-time keys.
7. EIP-712 `verifyingContract` must be the delegated EOA.
8. The wallet must persist local key consumption immediately after signing and before broadcast.
9. The wallet must reconcile against on-chain storage through `sync()`.
10. If local and on-chain state cannot be safely reconciled, the wallet must refuse to sign.

The browser wallet is experimental. It is not a production wallet, does not provide production-grade secret storage, and must only be used with local development accounts.

## Development status

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

Testing documentation is available in [`docs/testing.md`](docs/testing.md).

Known limitations include:

* no audit;
* no production hardening;
* no formal verification;
* no production-grade key custody;
* no encrypted browser wallet vault;
* no multi-device coordination;
* no production recovery UX;
* no support for real assets.

## License

TODO: add license information before publishing.
