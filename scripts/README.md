# Local E2E Scripts

This folder contains developer scripts for running and validating the local end-to-end flow.

The main entrypoint is:

```bash
./scripts/run-local-e2e.sh
```

It starts a local Anvil chain, deploys the account implementation, attaches EIP-7702 delegation, initializes the delegated account, deploys a test target, runs wallet operations, verifies edge cases, performs recovery, and checks the final state.

## Requirements

The script expects the following tools to be available:

- Foundry: `forge`, `cast`, `anvil`
- Node.js / pnpm for the `wallet/` package
- Bash

The script starts Anvil with the Prague hardfork:

```bash
anvil --hardfork prague --chain-id 31337
```

## Default environment

`run-local-e2e.sh` provides local defaults for Anvil:

```bash
RPC_URL=http://127.0.0.1:8545
CHAIN_ID=31337
DEPLOYER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
AUTHORITY_PRIVATE_KEY=0x59c6995e998f97a5a0044966f094538c9dae13912edc9a17e9d01ea2e7588d8c
RELAYER_PRIVATE_KEY=$DEPLOYER_PRIVATE_KEY
MNEMONIC="abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
WALLET_ID=0x1111111111111111111111111111111111111111111111111111111111111111
ACCOUNT_INDEX=0
```

These values are for local testing only.

## What the E2E flow does

The script performs the following sequence:

1. removes previous local wallet state;
2. starts Anvil with Prague;
3. runs `forge build`;
4. installs wallet dependencies;
5. runs wallet typecheck and tests;
6. deploys `EphemeralKeyAccount` implementation;
7. derives `auth[0]` and `recovery[0]` through `wallet/src/cli/prepare-local-init.ts`;
8. funds the delegated account and relayer;
9. attaches EIP-7702 delegation and initializes the delegated account;
10. deploys `ExecutionTarget`;
11. creates and syncs local wallet state;
12. executes `setNumber(111)`;
13. executes `alwaysRevert()` and verifies the account does not globally revert;
14. executes an expired `setNumber(222)` and verifies the target does not change;
15. executes a dev-only invalid `nextAuthorizedSigner` operation and verifies the account enters `PAUSED`;
16. performs signed recovery;
17. executes `setNumber(444)` after recovery;
18. prints the final state and burned key indices.

## Validated properties

The script validates the main local properties of the project:

- EIP-7702 delegation and initialization work locally;
- successful execution rotates the auth signer;
- target reverts do not roll back account-level rotation;
- expired operations can rotate the signer while skipping target execution;
- invalid `nextAuthorizedSigner` pauses the account;
- signed recovery restores the account to `READY`;
- post-recovery execution works;
- the target observes `msg.sender` as the delegated account.

## Logs

Logs are written under:

```text
.e2e/
```

The script writes separate logs for Anvil, build, wallet install, wallet tests, deployment, initialization, each wallet operation, recovery, and post-recovery execution.

If a step fails, the script prints the last log lines for the failed step.

## Manual components

The E2E script uses these Foundry scripts:

```text
script/DeployImplementation.s.sol
script/InitializeDelegatedAccount.s.sol
script/DeployExecutionTarget.s.sol
```

It uses these wallet commands:

```bash
pnpm prepare:init
pnpm state:init
pnpm sync
pnpm execute:set-number
pnpm execute:target-revert
pnpm execute:expired-set-number
pnpm execute:invalid-next-auth
pnpm recover
```

## Limitations

This E2E flow is intended for local development only.

It uses deterministic test accounts, a public test mnemonic, local JSON state, and a local relayer. It does not test production key storage, multi-device coordination, mainnet conditions, transaction replacement policies beyond the current viem receipt flow, or adversarial network/mempool behavior.
