import { browser } from "wxt/browser";
import type { LocalWalletState } from "../account/state.js";
import type { WalletStateStore } from "../core/types.js";
import type {
  ExtensionWalletSettings,
  ExtensionWalletSettingsInput,
} from "./types.js";
import {
  parseLocalWalletStateJson,
  validateSettingsInput,
} from "./validation.js";

const SETTINGS_KEY = "ephemeral-key-wallet:settings";
const STATE_KEY = "ephemeral-key-wallet:state";

export class ExtensionWalletStateStore implements WalletStateStore {
  async load(): Promise<LocalWalletState | null> {
    const result = await browser.storage.local.get(STATE_KEY);
    return (result[STATE_KEY] as LocalWalletState | undefined) ?? null;
  }

  async save(state: LocalWalletState): Promise<void> {
    await browser.storage.local.set({ [STATE_KEY]: state });
  }
}

export async function loadExtensionSettings(): Promise<ExtensionWalletSettings | null> {
  const result = await browser.storage.local.get(SETTINGS_KEY);
  return (result[SETTINGS_KEY] as ExtensionWalletSettings | undefined) ?? null;
}

export async function saveExtensionSettings(
  settings: ExtensionWalletSettings,
): Promise<void> {
  await browser.storage.local.set({ [SETTINGS_KEY]: settings });
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

  await browser.storage.local.set({ [STATE_KEY]: parsed.value });
}

export async function loadExtensionState(): Promise<LocalWalletState | null> {
  return new ExtensionWalletStateStore().load();
}

export async function clearExtensionWalletStorage(): Promise<void> {
  await browser.storage.local.remove([SETTINGS_KEY, STATE_KEY]);
}