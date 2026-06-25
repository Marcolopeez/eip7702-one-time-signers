# Browser Wallet Prototype

This document describes the first browser-wallet milestone for the EIP-7702 rotating-key account.

The extension is intentionally minimal. It is not a generic injected wallet and it does not expose `window.ethereum`. It is a local-development UI over the internal `OneTimeSignerWallet` SDK.

## Security boundary

The extension follows the same rule as the CLI and SDK:

```text
Producing a signature burns the corresponding local key immediately.
```

The popup never derives private keys directly and never calls the low-level EIP-712 signing helpers. It sends messages to the background service worker, and the background code calls the SDK methods:

```ts
wallet.sync();
wallet.execute({ target, value, data });
wallet.recover();
```

The security-sensitive sequence remains centralized in `src/core/OneTimeSignerWallet.ts`:

```text
sync -> derive -> sign -> burn locally -> persist -> broadcast -> sync
```

## Current scope

The prototype supports:

- storing local development settings in extension storage;
- importing an existing `LocalWalletState` JSON;
- displaying account status and current signer indices;
- syncing against the delegated account;
- executing `ExecutionTarget.setNumber(uint256)`;
- running `signedRecovery()` when the account is paused.

The prototype intentionally does not support:

- injecting `window.ethereum`;
- connecting arbitrary dapps;
- arbitrary `eth_sign`, `personal_sign`, or `eth_sendTransaction` requests;
- multi-account or multi-device flows;
- production-grade encrypted secret storage.

## Why background-only wallet actions

Manifest V3 background pages are replaced by service workers, which are started when needed and should not be treated as long-lived memory. For this account model, storage is part of the security boundary because a key must be marked burned immediately after signing. The extension therefore persists wallet state through the storage adapter before broadcasting a transaction.

The popup is only a UI. It sends typed messages to the background script. The background script owns wallet construction and action execution.

## Local development setup

From `wallet/`:

```bash
pnpm install
pnpm extension:dev
```

The extension popup expects local Anvil-compatible data from the previous CLI milestones:

- mnemonic;
- relayer private key;
- RPC URL;
- `ExecutionTarget` address;
- the existing `.local/state.json` contents pasted into the `LocalWalletState JSON` field.

Use only Anvil/test keys. Do not use a real mnemonic or real funds.

### Chrome path on Linux

If `pnpm extension:dev` builds the extension but fails with `CHROME_PATH environment variable must be set`, point WXT to your browser executable:

```bash
export CHROME_PATH="$(which chromium)"
pnpm extension:dev
```

Other common values are:
```bash
export CHROME_PATH="$(which google-chrome)"
export CHROME_PATH="$(which google-chrome-stable)"
export CHROME_PATH="$(which brave-browser)"
export CHROME_PATH="$(which brave)"
```

## Import/export UX

The popup separates wallet settings from local wallet state.

Settings include:

- mnemonic;
- optional passphrase;
- RPC URL;
- relayer private key;
- optional `ExecutionTarget` address.

The local wallet state can be imported separately by pasting the contents of `wallet/.local/state.json`.

After every successful wallet action, the popup refreshes the current state from extension storage. The user can copy or download the updated state.

For development convenience, once mnemonic and relayer key have been stored, the settings form can be saved again leaving those fields empty. The background keeps the previously stored values.

This is still a development-only flow. A production wallet must replace this with encrypted secret storage and a proper unlock lifecycle.

## Typical flow

1. Run the CLI setup and initialize the delegated EOA.
2. Deploy `ExecutionTarget`.
3. Open the extension popup.
4. Paste:
   - development mnemonic;
   - relayer private key;
   - RPC URL, usually `http://127.0.0.1:8545`;
   - `ExecutionTarget` address;
   - contents of `wallet/.local/state.json`.
5. Click `Save configuration`.
6. Click `Sync`.
7. If the account is `READY`, execute `setNumber`.
8. If the account is `PAUSED`, run `Recover`.

## Files

```text
wallet/wxt.config.ts
wallet/entrypoints/background.ts
wallet/entrypoints/popup/index.html
wallet/entrypoints/popup/main.tsx
wallet/entrypoints/popup/App.tsx
wallet/entrypoints/popup/style.css
wallet/src/extension/types.ts
wallet/src/extension/storage.ts
wallet/src/extension/backgroundWallet.ts
```

## Production hardening still required

Before this can become a real wallet, the following are required:

- encrypted mnemonic storage using a user password and a strong KDF;
- unlock/lock lifecycle;
- no plaintext display or persistence of secrets after import;
- strict origin permissions and explicit user confirmations;
- a formal message schema with runtime validation;
- robust transaction replacement and pending-state recovery UX;
- separation between development-only operations and production flows;
- independent audit of the extension privilege boundary.
