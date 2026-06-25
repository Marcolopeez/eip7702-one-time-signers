/** Shared CLI bootstrap for the SDK-backed scripts. */
import { OneTimeSignerAccountClient } from "../../../adapters/viem/OneTimeSignerAccountClient.js";
import { JsonWalletStateStore } from "../../../adapters/storage/JsonWalletStateStore.js";
import { OneTimeSignerWallet } from "../../../sdk/OneTimeSignerWallet.js";
import { optionalEnv, requireEnv, requireHexEnv } from "./env.js";

export type CreateWalletFromEnvOptions = {
  requireRelayer?: boolean;
};

export async function createWalletFromEnv(
  options: CreateWalletFromEnvOptions = {},
) {
  const requireRelayer = options.requireRelayer ?? false;

  const statePath = optionalEnv("STATE_IN", ".local/state.json");
  const rpcUrl = optionalEnv("RPC_URL", "http://127.0.0.1:8545");
  const mnemonic = requireEnv("MNEMONIC");
  const passphrase = optionalEnv("BIP39_PASSPHRASE", "");

  const store = new JsonWalletStateStore(statePath);
  const state = await store.load();

  if (!state) {
    throw new Error(`No wallet state found at ${statePath}`);
  }

  const relayerPrivateKey = requireRelayer
    ? requireHexEnv("RELAYER_PRIVATE_KEY")
    : undefined;

  const client = new OneTimeSignerAccountClient({
    rpcUrl,
    chainId: state.chainId,
    delegatedAccount: state.delegatedAccount,
    ...(relayerPrivateKey !== undefined ? { relayerPrivateKey } : {}),
  });

  const wallet = new OneTimeSignerWallet({
    mnemonic,
    passphrase,
    store,
    client,
  });

  return {
    wallet,
    client,
    store,
    state,
    statePath,
    rpcUrl,
  };
}