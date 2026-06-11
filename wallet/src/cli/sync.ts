/**
 * Reconciles the persisted local wallet state with the delegated account.
 *
 * This command is safe to run often. It does not sign or send transactions.
 */
import { EphemeralAccountClient } from "../account/client.js";
import { JsonLocalStore } from "../storage/localStore.js";
import { optionalEnv } from "./env.js";

const statePath = optionalEnv("STATE_IN", ".local/state.json");
const rpcUrl = optionalEnv("RPC_URL", "http://127.0.0.1:8545");

const store = new JsonLocalStore(statePath);
const state = await store.load();

if (!state) {
  throw new Error(`No wallet state found at ${statePath}`);
}

const client = new EphemeralAccountClient({
  rpcUrl,
  chainId: state.chainId,
  delegatedAccount: state.delegatedAccount,
});

// sync() reads storage and applies the pure reconciliation rules.
const result = await client.sync(state);

console.log("Sync result");
console.log("-----------");
console.log("reason:     ", result.reason);
console.log("changed:    ", result.changed);
console.log("status:     ", result.state.status);
console.log("auth signer:", result.state.currentAuthorizedSigner);

if (result.changed) {
  await store.save(result.state);
  console.log("");
  console.log(`Saved updated state to ${statePath}`);
}