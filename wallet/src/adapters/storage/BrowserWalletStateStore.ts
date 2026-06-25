import { browser } from "wxt/browser";
import type { LocalWalletState } from "../../protocol/one-time-signer-account/state.js";
import type { WalletStateStore } from "../../sdk/ports.js";

export const BROWSER_WALLET_STATE_KEY = "one-time-signer-wallet:state";

/**
 * Browser-extension-backed wallet state store.
 *
 * This adapter stores only LocalWalletState. It deliberately does not know
 * about extension settings such as mnemonic, RPC URL or relayer private key.
 *
 * Keeping this adapter narrow makes it usable by the SDK without coupling the
 * SDK to extension-specific configuration.
 */
export class BrowserWalletStateStore implements WalletStateStore {
  async load(): Promise<LocalWalletState | null> {
    const result = await browser.storage.local.get(BROWSER_WALLET_STATE_KEY);

    return (
      (result[BROWSER_WALLET_STATE_KEY] as LocalWalletState | undefined) ?? null
    );
  }

  async save(state: LocalWalletState): Promise<void> {
    await browser.storage.local.set({
      [BROWSER_WALLET_STATE_KEY]: state,
    });
  }

  async clear(): Promise<void> {
    await browser.storage.local.remove(BROWSER_WALLET_STATE_KEY);
  }
}