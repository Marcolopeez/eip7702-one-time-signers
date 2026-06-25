# Scripts

## Status

These scripts are local/dev tooling for the experimental prototype.

They are intended for contributors who need to run the local EIP-7702 flow, validate wallet/contract integration, or work on the Foundry setup. They are not production deployment tooling and must not be used with real assets.

## Directory roles

This repository has two script directories with different roles:

| Directory  | Purpose                                                                  |
| ---------- | ------------------------------------------------------------------------ |
| `scripts/` | Shell scripts that orchestrate local workflows from the repository root. |
| `script/`  | Foundry scripts written in Solidity and executed with `forge script`.    |

Use `scripts/` for full local flows.

Use `script/` when you need to deploy or initialize one piece of the local setup directly.

## Local e2e script

### `scripts/run-local-e2e.sh`

Runs the complete local EIP-7702 wallet scenario against a fresh Prague Anvil chain.

From the repository root:

```bash
./scripts/run-local-e2e.sh
```

The script:

1. Cleans previous local wallet state under `wallet/.local`.
2. Starts Anvil with the Prague hardfork.
3. Runs `forge build`.
4. Installs wallet dependencies with `pnpm install`.
5. Runs wallet type checking and tests.
6. Deploys the `OneTimeSignerAccount` implementation.
7. Runs the wallet init preparation flow to derive the first auth and recovery signers.
8. Funds the delegated account and relayer in Anvil.
9. Attaches EIP-7702 delegation and initializes the delegated EOA.
10. Deploys the local `ExecutionTarget` test contract.
11. Creates and syncs local wallet state.
12. Executes the local CLI flows:

    * successful `setNumber`;
    * target revert;
    * expired operation;
    * invalid next authorized signer;
    * signed recovery;
    * post-recovery execution.
13. Writes logs to `.e2e/`.

The script uses deterministic Anvil development keys and deterministic wallet inputs by default. Override the exported environment variables only for local testing scenarios.

## Foundry scripts

Foundry scripts live in `script/` and are executed with `forge script`.

### `DeployImplementation.s.sol`

Deploys the reusable `OneTimeSignerAccount` implementation contract.

This script only deploys the implementation. It does not initialize an account and does not attach EIP-7702 delegation.

Required environment variable:

```bash
DEPLOYER_PRIVATE_KEY
```

The script logs:

* implementation address;
* chain ID.

### `DeployExecutionTarget.s.sol`

Deploys the local `ExecutionTarget` mock used by the e2e flow.

This target is used to exercise successful calls, sender checks, state changes, and target-level reverts from the delegated account.

Required environment variable:

```bash
DEPLOYER_PRIVATE_KEY
```

The script logs the deployed target address.

### `InitializeDelegatedAccount.s.sol`

Attaches EIP-7702 delegation to the authority EOA and initializes its delegated account storage.

Required environment variables:

```bash
AUTHORITY_PRIVATE_KEY
IMPLEMENTATION_ADDRESS
FIRST_AUTHORIZED_SIGNER
FIRST_RECOVERY_SIGNER
```

The script:

1. Resolves the authority address from `AUTHORITY_PRIVATE_KEY`.
2. Attaches delegation from the authority EOA to `IMPLEMENTATION_ADDRESS`.
3. Calls `initialize()` through the delegated EOA.
4. Stores the first authorized signer.
5. Registers the first recovery signer.
6. Checks that the delegated account is initialized, unpaused, and configured with the expected signers.

Under EIP-7702, initialization writes to the delegated EOA storage, not to the implementation contract storage.

## Related documentation

Main usage docs:

* [`docs/quickstart.md`](../docs/quickstart.md)
* [`docs/testing.md`](../docs/testing.md)
* [`docs/cli.md`](../docs/cli.md)
