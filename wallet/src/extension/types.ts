import type { Address, Hex } from "viem";
import type { LocalWalletState } from "../account/state.js";
import type { SyncReason } from "../account/sync.js";

export type ExtensionWalletSettings = {
  mnemonic: string;
  passphrase?: string;
  rpcUrl: string;
  relayerPrivateKey: Hex;
  executionTargetAddress?: Address;
};

export type ExtensionWalletSettingsInput = {
  /**
   * Optional after first save.
   *
   * If omitted, the background keeps the previously stored mnemonic.
   */
  mnemonic?: string;

  /**
   * Optional. If omitted, the background keeps the previous passphrase.
   */
  passphrase?: string;

  rpcUrl: string;

  /**
   * Optional after first save.
   *
   * If omitted, the background keeps the previously stored relayer key.
   */
  relayerPrivateKey?: Hex;

  executionTargetAddress?: Address;
};

export type ExtensionSnapshot = {
  hasSettings: boolean;
  hasState: boolean;
  settings?: {
    rpcUrl: string;
    relayerConfigured: boolean;
    executionTargetAddress?: Address;
    mnemonicConfigured: boolean;
    passphraseConfigured: boolean;
  };
  state?: LocalWalletState;
};

export type ActionSummary = {
  txHash?: Hex;
  syncReason?: SyncReason;
  status?: LocalWalletState["status"];
  currentAuthIndex?: number;
  currentAuthorizedSigner?: Address;
  currentRecoveryIndex?: number;
  currentRecoverySigner?: Address;
};

export type ExtensionRequest =
  | { type: "GET_SNAPSHOT" }
  | {
      type: "SAVE_SETTINGS";
      settings: ExtensionWalletSettingsInput;
      stateJson?: string;
    }
  | { type: "SAVE_STATE_JSON"; stateJson: string }
  | { type: "CLEAR_ALL" }
  | { type: "SYNC" }
  | { type: "EXECUTE_SET_NUMBER"; newNumber: string }
  | { type: "RECOVER" };

export type ExtensionResponse<T = unknown> =
  | { ok: true; data: T }
  | { ok: false; error: string };