# Local E2E Scripts

This folder contains developer scripts for validating the local end-to-end flow of the EIP-7702 rotating-key account.

The main entrypoint is:

```bash
./scripts/run-local-e2e.sh
```

It starts a fresh Anvil chain, deploys the account implementation, attaches EIP-7702 delegation to an EOA, initializes delegated-account storage, deploys a target contract, runs wallet operations, exercises failure semantics, performs recovery, and checks the final state.

## Requirements

The script expects these tools to be available:

- Foundry: `forge`, `cast`, `anvil`
- Node.js and `pnpm`
- Bash

The script starts Anvil with the Prague hardfork because the flow depends on EIP-7702:

```bash
anvil --hardfork prague --chain-id 31337
```

## Default local environment

`run-local-e2e.sh` provides deterministic local defaults:

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

These values are for local testing only. They are public development keys and a public test mnemonic.

## What the E2E flow validates

The script performs this sequence:

1. removes previous local wallet state;
2. starts Anvil with Prague;
3. runs `forge build`;
4. installs wallet dependencies;
5. runs wallet typecheck and unit tests;
6. deploys `EphemeralKeyAccount` implementation;
7. derives `auth[0]` and `recovery[0]` through `wallet/src/cli/prepare-local-init.ts`;
8. funds the delegated account and relayer;
9. attaches EIP-7702 delegation and initializes delegated-account storage;
10. deploys `ExecutionTarget`;
11. creates and syncs local wallet state;
12. executes a successful `setNumber(111)` operation;
13. executes `alwaysRevert()` and verifies signer rotation is not rolled back;
14. executes an expired `setNumber(222)` and verifies the target is not called while the signer still rotates;
15. executes a dev-only invalid `nextAuthorizedSigner` operation and verifies the account enters `PAUSED`;
16. performs signed recovery with a fresh auth signer and fresh recovery signer;
17. executes `setNumber(444)` after recovery;
18. prints final state and burned key indices.

## Design properties exercised

The E2E flow is intended to test the interaction between the contract and wallet, not only isolated functions.

It validates that:

- EIP-7702 delegation and delegated storage work locally;
- the EIP-712 verifying contract is the delegated EOA;
- successful execution rotates the auth signer;
- the relayer pays gas but does not authorize the operation;
- target reverts do not roll back account-level rotation;
- expired operations can rotate the signer while skipping target execution;
- invalid `nextAuthorizedSigner` pauses the account;
- wallet state burns keys before broadcast;
- signed recovery consumes the recovery key and installs fresh auth/recovery signers;
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

This E2E flow is local-development coverage only.

It does not test:

- secure key storage;
- encrypted wallet state;
- production relayer infrastructure;
- mainnet gas or mempool conditions;
- dropped/replaced transaction policies;
- chain reorgs;
- multi-device coordination;
- adversarial event indexing;
- the EIP-7702 authority-key lifecycle after delegation.

For the broader design and security notes, see [`../docs/README.md`](../docs/README.md).
