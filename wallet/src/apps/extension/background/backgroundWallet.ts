import { encodeFunctionData, getAddress } from "viem";
import { OneTimeSignerAccountClient } from "../../../adapters/viem/OneTimeSignerAccountClient.js";
import { BrowserWalletStateStore } from "../../../adapters/storage/BrowserWalletStateStore.js";
import { executionTargetAbi } from "../../../contracts/ExecutionTarget.abi.js";
import { OneTimeSignerWallet } from "../../../sdk/OneTimeSignerWallet.js";
import type { ActionSummary, ExtensionSnapshot } from "../messaging/types.js";
import {
  loadExtensionSettings,
  loadExtensionState,
} from "../config/storage.js";

async function requireSettings() {
  const settings = await loadExtensionSettings();

  if (!settings) {
    throw new Error("Wallet settings are not configured");
  }

  return settings;
}

async function requireState() {
  const state = await loadExtensionState();

  if (!state) {
    throw new Error("Wallet state is not imported");
  }

  return state;
}

export async function getExtensionSnapshot(): Promise<ExtensionSnapshot> {
  const [settings, state] = await Promise.all([
    loadExtensionSettings(),
    loadExtensionState(),
  ]);

  return {
    hasSettings: settings !== null,
    hasState: state !== null,
    ...(settings
      ? {
          settings: {
            rpcUrl: settings.rpcUrl,
            relayerConfigured: settings.relayerPrivateKey.length > 2,
            ...(settings.executionTargetAddress
              ? { executionTargetAddress: settings.executionTargetAddress }
              : {}),
            mnemonicConfigured: settings.mnemonic.trim().length > 0,
            passphraseConfigured: (settings.passphrase ?? "").length > 0,
          },
        }
      : {}),
    ...(state ? { state } : {}),
  };
}

export async function createExtensionWallet(): Promise<OneTimeSignerWallet> {
  const settings = await requireSettings();
  const state = await requireState();

  const store = new BrowserWalletStateStore();

  const client = new OneTimeSignerAccountClient({
    rpcUrl: settings.rpcUrl,
    chainId: state.chainId,
    delegatedAccount: state.delegatedAccount,
    relayerPrivateKey: settings.relayerPrivateKey,
  });

  return new OneTimeSignerWallet({
    mnemonic: settings.mnemonic,
    ...(settings.passphrase !== undefined
      ? { passphrase: settings.passphrase }
      : {}),
    store,
    client,
  });
}

function summarizeState(
  state: Awaited<ReturnType<OneTimeSignerWallet["getState"]>>,
): ActionSummary {
  return {
    status: state.status,
    currentAuthIndex: state.currentAuthIndex,
    currentAuthorizedSigner: state.currentAuthorizedSigner,
    currentRecoveryIndex: state.currentRecoveryIndex,
    currentRecoverySigner: state.currentRecoverySigner,
  };
}

export async function syncExtensionWallet(): Promise<ActionSummary> {
  const wallet = await createExtensionWallet();
  const result = await wallet.sync();

  return {
    syncReason: result.reason,
    ...summarizeState(result.state),
  };
}

export async function executeExtensionSetNumber(
  newNumber: bigint,
): Promise<ActionSummary> {
  const settings = await requireSettings();

  if (!settings.executionTargetAddress) {
    throw new Error("Execution target address is not configured");
  }

  const wallet = await createExtensionWallet();

  const data = encodeFunctionData({
    abi: executionTargetAbi,
    functionName: "setNumber",
    args: [newNumber],
  });

  const result = await wallet.execute({
    target: getAddress(settings.executionTargetAddress),
    value: 0n,
    data,
  });

  return {
    txHash: result.txHash,
    syncReason: result.syncResult.reason,
    ...summarizeState(result.state),
  };
}

export async function recoverExtensionWallet(): Promise<ActionSummary> {
  const wallet = await createExtensionWallet();
  const result = await wallet.recover();

  return {
    txHash: result.txHash,
    syncReason: result.syncResult.reason,
    ...summarizeState(result.state),
  };
}