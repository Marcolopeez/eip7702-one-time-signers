import { defineBackground } from "wxt/utils/define-background";
import { browser } from "wxt/browser";
import type {
  ExtensionRequest,
  ExtensionResponse,
} from "../src/apps/extension/messaging/types.js";
import {
  clearExtensionWalletStorage,
  mergeAndSaveExtensionSettings,
  saveExtensionStateJson,
} from "../src/apps/extension/config/storage.js";
import {
  executeExtensionSetNumber,
  getExtensionSnapshot,
  recoverExtensionWallet,
  syncExtensionWallet,
} from "../src/apps/extension/background/backgroundWallet.js";

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function handleMessage(
  message: ExtensionRequest,
): Promise<ExtensionResponse> {
  switch (message.type) {
    case "GET_SNAPSHOT":
      return { ok: true, data: await getExtensionSnapshot() };

    case "SAVE_SETTINGS": {
      await mergeAndSaveExtensionSettings(message.settings);

      if (message.stateJson?.trim()) {
        await saveExtensionStateJson(message.stateJson);
      }

      return { ok: true, data: await getExtensionSnapshot() };
    }

    case "SAVE_STATE_JSON":
      await saveExtensionStateJson(message.stateJson);
      return { ok: true, data: await getExtensionSnapshot() };

    case "CLEAR_ALL":
      await clearExtensionWalletStorage();
      return { ok: true, data: await getExtensionSnapshot() };

    case "SYNC":
      return { ok: true, data: await syncExtensionWallet() };

    case "EXECUTE_SET_NUMBER":
      return {
        ok: true,
        data: await executeExtensionSetNumber(BigInt(message.newNumber)),
      };

    case "RECOVER":
      return { ok: true, data: await recoverExtensionWallet() };
  }
}

export default defineBackground(() => {
  browser.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    handleMessage(message as ExtensionRequest)
      .then(sendResponse)
      .catch((error) =>
        sendResponse({
          ok: false,
          error: errorMessage(error),
        }),
      );

    return true;
  });
});