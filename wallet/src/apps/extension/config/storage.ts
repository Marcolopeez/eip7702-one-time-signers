import { browser } from "wxt/browser";
import { BrowserWalletStateStore } from "../../../adapters/storage/BrowserWalletStateStore.js";
import type { LocalWalletState } from "../../../protocol/one-time-signer-account/state.js";
import type {
  ExtensionWalletSettings,
  ExtensionWalletSettingsInput,
} from "../messaging/types.js";
import {
  parseLocalWalletStateJson,
  validateSettingsInput,
} from "./validation.js";

const SETTINGS_KEY = "one-time-signer-wallet:settings";

export async function loadExtensionSettings(): Promise<ExtensionWalletSettings | null> {
  const result = await browser.storage.local.get(SETTINGS_KEY);

  return (
    (result[SETTINGS_KEY] as ExtensionWalletSettings | undefined) ?? null
  );
}

export async function saveExtensionSettings(
  settings: ExtensionWalletSettings,
): Promise<void> {
  await browser.storage.local.set({
    [SETTINGS_KEY]: settings,
  });
}

export async function mergeAndSaveExtensionSettings(
  input: ExtensionWalletSettingsInput,
): Promise<void> {
  const previous = await loadExtensionSettings();
  const validated = validateSettingsInput(input, previous);

  if (!validated.ok) {
    throw new Error(validated.error);
  }

  await saveExtensionSettings(validated.value);
}

export async function saveExtensionStateJson(stateJson: string): Promise<void> {
  const parsed = parseLocalWalletStateJson(stateJson);

  if (!parsed.ok) {
    throw new Error(parsed.error);
  }

  const store = new BrowserWalletStateStore();
  await store.save(parsed.value);
}

export async function loadExtensionState(): Promise<LocalWalletState | null> {
  const store = new BrowserWalletStateStore();
  return store.load();
}

export async function clearExtensionWalletStorage(): Promise<void> {
  const store = new BrowserWalletStateStore();

  await Promise.all([
    browser.storage.local.remove(SETTINGS_KEY),
    store.clear(),
  ]);
}