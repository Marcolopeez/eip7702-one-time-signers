/**
 * Creates the first local state file after on-chain initialization.
 *
 * The script verifies that derived auth[0]/recovery[0] match init.json and then
 * runs sync() so local state is only saved if on-chain storage agrees.
 */
import { readFile } from "node:fs/promises";
import { getAddress } from "viem";
import type { DerivationContext } from "../crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../crypto/derivation.js";
import { createInitialWalletState } from "../account/state.js";
import { EphemeralAccountClient } from "../account/client.js";
import { JsonLocalStore } from "../storage/localStore.js";
import {
  optionalEnv,
  requireEnv,
  requireHexEnv,
} from "./env.js";

type InitJson = {
  chainId: number;
  accountIndex: number;
  delegatedAccount: string;
  implementationAddress: string;
  firstAuthorizedSigner: string;
  firstRecoverySigner: string;
  authIndex: number;
  recoveryIndex: number;
};

const initPath = optionalEnv("INIT_IN", ".local/init.json");
const statePath = optionalEnv("STATE_OUT", ".local/state.json");
const rpcUrl = optionalEnv("RPC_URL", "http://127.0.0.1:8545");

const mnemonic = requireEnv("MNEMONIC");
const walletId = requireHexEnv("WALLET_ID");

// init.json is produced by prepare-local-init.ts and consumed after initialize().
const init = JSON.parse(await readFile(initPath, "utf8")) as InitJson;

const delegatedAccount = getAddress(init.delegatedAccount);
const implementationAddress = getAddress(init.implementationAddress);

const derivationContext: DerivationContext = {
  mnemonic,
  passphrase: optionalEnv("BIP39_PASSPHRASE", ""),
  walletId,
  chainId: init.chainId,
  delegatedAccount,
  implementationAddress,
  accountIndex: init.accountIndex,
};

const auth0 = deriveAuthSigner(derivationContext, init.authIndex);
const recovery0 = deriveRecoverySigner(derivationContext, init.recoveryIndex);

// Refuse to create state if the local derivation context has drifted.
if (auth0.address !== getAddress(init.firstAuthorizedSigner)) {
  throw new Error(
    `Derived auth[0] does not match init.json: ${auth0.address} != ${init.firstAuthorizedSigner}`,
  );
}

if (recovery0.address !== getAddress(init.firstRecoverySigner)) {
  throw new Error(
    `Derived recovery[0] does not match init.json: ${recovery0.address} != ${init.firstRecoverySigner}`,
  );
}

const state = createInitialWalletState({
  chainId: init.chainId,
  delegatedAccount,
  implementationAddress,
  walletId,
  accountIndex: init.accountIndex,

  initialAuthIndex: init.authIndex,
  initialAuthorizedSigner: auth0.address,

  initialRecoveryIndex: init.recoveryIndex,
  initialRecoverySigner: recovery0.address,
});

const client = new EphemeralAccountClient({
  rpcUrl,
  chainId: init.chainId,
  delegatedAccount,
});

// The contract storage is the final source of truth for the initial state.
const syncResult = await client.sync(state);

if (syncResult.reason !== "UNCHANGED_READY") {
  throw new Error(
    `Initial on-chain state does not match local READY state. Sync reason: ${syncResult.reason}`,
  );
}

const store = new JsonLocalStore(statePath);
await store.save(syncResult.state);

console.log("Initial wallet state created");
console.log("----------------------------");
console.log("state:              ", statePath);
console.log("delegatedAccount:   ", delegatedAccount);
console.log("auth[0]:            ", auth0.address);
console.log("recovery[0]:        ", recovery0.address);
console.log("sync reason:        ", syncResult.reason);