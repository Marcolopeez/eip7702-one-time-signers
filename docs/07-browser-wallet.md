# Experimental Browser Wallet

## Status

The browser wallet is an experimental local-development prototype for the One-Time Signer Account project.

It is not production-ready. It must not be used with real assets, real mnemonics, production RPC endpoints, or accounts that hold value.

The extension currently stores sensitive configuration in browser extension local storage. This includes the mnemonic and relayer private key. There is no encrypted vault, unlock flow, password-based key protection, origin isolation model, or production-grade wallet UX.

Use it only with local Anvil/test deployments.

## Purpose

The browser wallet exists to test how the one-time signer account model can be driven from a browser extension environment.

Its role is to provide a minimal UI over the existing wallet SDK and protocol state machine. It is not a generic Ethereum wallet and does not attempt to implement normal dapp wallet behavior.

The extension exposes these prototype flows from a browser UI:

* import existing local wallet state;
* store local development configuration;
* sync local state against the delegated account;
* execute the demo `ExecutionTarget.setNumber(uint256)` operation;
* recover a paused account using the one-time recovery flow;
* inspect, copy, and download the updated local wallet state.

The security-sensitive signing sequence remains centralized in the SDK:

```text
sync -> derive -> sign -> burn locally -> persist -> broadcast -> sync
```

UI code must not call low-level EIP-712 signing helpers directly.

## Current capabilities

The current extension supports:

* WXT-based browser extension development.
* React popup UI.
* A shared wallet UI component used by the extension interface.
* Local extension storage for:

  * wallet settings;
  * imported `LocalWalletState`.
* Runtime validation for:

  * RPC URL;
  * relayer private key;
  * optional `ExecutionTarget` address;
  * imported local wallet state JSON.
* Importing `LocalWalletState` JSON, usually from `wallet/.local/state.json`.
* Displaying:

  * delegated account;
  * account status;
  * current auth signer index;
  * current auth signer address;
  * current recovery signer index;
  * current recovery signer address.
* Running `sync()`.
* Executing `ExecutionTarget.setNumber(uint256)` through the SDK.
* Running recovery when the local state is `PAUSED`.
* Showing the last action summary:

  * transaction hash, when available;
  * sync reason;
  * resulting account status;
  * signer indices.
* Copying or downloading the current local state JSON.
* Clearing extension wallet storage.

The extension is configured for local RPC hosts only:

```text
http://127.0.0.1/*
http://localhost/*
```

## Non-goals and limitations

The browser wallet does not currently support:

* real funds;
* production use;
* encrypted mnemonic storage;
* password-based unlock or lock lifecycle;
* seed generation;
* account creation from the extension UI;
* EIP-7702 delegation setup from the extension UI;
* implementation deployment;
* arbitrary contract calls;
* arbitrary transaction construction;
* arbitrary `eth_sendTransaction`;
* `eth_sign`;
* `personal_sign`;
* typed-data signing for external callers;
* injected provider support;
* `window.ethereum`;
* generic dapp compatibility;
* wallet connection flows;
* origin-based request permissions;
* user confirmation screens for external sites;
* multi-account support;
* multi-network account management;
* multi-device synchronization;
* transaction replacement handling;
* robust pending-transaction recovery UX;
* production-grade secret handling.

The only operation exposed by the current UI is the demo `ExecutionTarget.setNumber(uint256)` call.

## Extension structure

### WXT configuration

File:

```text
wallet/wxt.config.ts
```

The extension uses WXT with the React module.

The manifest declares:

* extension name: `One-Time Signer Wallet`;
* description: experimental EIP-7702 one-time-key wallet for local development;
* version: `0.1.0`;
* `storage` permission;
* local host permissions for `127.0.0.1` and `localhost`.

This matches the current local-development scope. It should not be interpreted as a production permission model.

### Entrypoints

Current relevant files:

```text
wallet/entrypoints/background.ts
wallet/entrypoints/popup/App.tsx
wallet/entrypoints/popup/main.tsx
wallet/entrypoints/options/index.html
wallet/entrypoints/options/main.tsx
```

The popup entrypoint renders the shared wallet UI in popup mode:

```ts
<WalletApp mode="popup" />
```

The popup also exposes an `Open dashboard` button that calls:

```ts
browser.runtime.openOptionsPage()
```

Implementation note: the shared UI supports a `dashboard` mode. Keep the options entrypoint aligned with that mode if the dashboard page is used.

### Background logic

File:

```text
wallet/src/apps/extension/background/backgroundWallet.ts
```

The background logic owns wallet construction and execution. It loads settings and local wallet state from extension storage, then creates:

* `BrowserWalletStateStore`;
* `OneTimeSignerAccountClient`;
* `OneTimeSignerWallet`.

The background exposes these wallet actions to the extension message handler:

```ts
getExtensionSnapshot()
syncExtensionWallet()
executeExtensionSetNumber(newNumber)
recoverExtensionWallet()
```

`executeExtensionSetNumber()` encodes a call to:

```solidity
ExecutionTarget.setNumber(uint256)
```

and sends it through:

```ts
wallet.execute({
  target,
  value: 0n,
  data,
});
```

Recovery is sent through:

```ts
wallet.recover();
```

### Message handling

Files:

```text
wallet/entrypoints/background.ts
wallet/src/apps/extension/messaging/types.ts
```

The popup communicates with the background service worker using typed extension messages.

Supported request types:

```ts
GET_SNAPSHOT
SAVE_SETTINGS
SAVE_STATE_JSON
CLEAR_ALL
SYNC
EXECUTE_SET_NUMBER
RECOVER
```

The background handler catches errors and returns either:

```ts
{ ok: true, data }
```

or:

```ts
{ ok: false, error }
```

This is a local extension message protocol. It is not a dapp-facing wallet RPC API.

### Popup UI

File:

```text
wallet/src/apps/extension/ui/WalletApp.tsx
```

The UI provides:

* experimental-use warning;
* account state summary;
* `Sync` action;
* `Execute setNumber` action;
* `Recover` action;
* settings form;
* state import/export panel;
* copy/download state actions;
* storage clearing.

The execute button is enabled only when local state is `READY`.

The recover button is enabled only when local state is `PAUSED`.

### Storage configuration

Files:

```text
wallet/src/apps/extension/config/storage.ts
wallet/src/apps/extension/config/validation.ts
wallet/src/adapters/storage/BrowserWalletStateStore.ts
```

Settings and wallet state are stored separately.

Settings are stored under:

```text
one-time-signer-wallet:settings
```

Settings include:

* mnemonic;
* optional passphrase;
* RPC URL;
* relayer private key;
* optional `ExecutionTarget` address.

Local wallet state is stored under:

```text
one-time-signer-wallet:state
```

The `BrowserWalletStateStore` stores only `LocalWalletState`. It deliberately does not know about extension settings. This keeps the SDK storage adapter narrow and avoids coupling the SDK to extension-specific configuration.

### Validation

File:

```text
wallet/src/apps/extension/config/validation.ts
```

The extension validates settings and imported state before persisting them.

Current validation covers:

* `http` or `https` RPC URLs;
* 32-byte `0x`-prefixed relayer private keys;
* optional address normalization through `viem`;
* state `schemaVersion`;
* required local state addresses;
* signer indices;
* burned auth/recovery index arrays;
* supported local state statuses:

  * `READY`;
  * `PENDING_OPERATION`;
  * `PAUSED`;
  * `PENDING_RECOVERY`.

This validation is useful for local development, but it is not a full security boundary for a production wallet.

### SDK and protocol reuse

The extension reuses the same wallet SDK and protocol modules as the CLI.

Relevant files:

```text
wallet/src/sdk/OneTimeSignerWallet.ts
wallet/src/protocol/one-time-signer-account/state.ts
wallet/src/protocol/one-time-signer-account/sync.ts
wallet/src/protocol/one-time-signer-account/eip712.ts
wallet/src/protocol/one-time-signer-account/signerSelection.ts
wallet/src/adapters/viem/OneTimeSignerAccountClient.ts
```

The browser UI does not derive signer private keys directly. It sends high-level requests to the background script, and the background script calls SDK methods.

This keeps the one-time-key rules in one place.

## Development

Run extension development commands from `wallet/`.

Install dependencies first:

```bash
pnpm install
```

Start the WXT development server:

```bash
pnpm extension:dev
```

The extension expects an already initialized local account state. A typical local flow is:

1. Start the local chain and deploy the contracts.
2. Initialize the delegated EOA using the CLI/local scripts.
3. Import the generated `wallet/.local/state.json` into the extension.
4. Save local development settings:

   * mnemonic;
   * optional passphrase;
   * RPC URL, usually `http://127.0.0.1:8545`;
   * relayer private key;
   * `ExecutionTarget` address.
5. Click `Sync`.
6. Execute `setNumber` when the account is `READY`.
7. Run `Recover` if the account is `PAUSED`.

Use only test mnemonics and test private keys.

## Build and type checking

Run from `wallet/`.

Build the extension:

```bash
pnpm extension:build
```

Typecheck the extension:

```bash
pnpm typecheck:extension
```

The extension typecheck command runs WXT preparation before TypeScript:

```bash
wxt prepare && tsc --noEmit -p tsconfig.extension.json
```

The extension TypeScript configuration includes:

```text
src
entrypoints
wxt.config.ts
```

and uses strict TypeScript settings.

## State storage and synchronization

The extension uses `BrowserWalletStateStore` for `LocalWalletState`. This state is security-sensitive because it records burned signer indices and pending signatures.

Settings and wallet state are stored separately:

| Data | Storage key | Notes |
| ---- | ----------- | ----- |
| Extension settings | `one-time-signer-wallet:settings` | Includes local-development configuration such as mnemonic, RPC URL, relayer private key, and optional execution target. |
| Wallet state | `one-time-signer-wallet:state` | Contains `LocalWalletState` used by the SDK. |

The SDK still owns the signing and persistence sequence. The UI sends high-level requests to the background script; it does not derive signer private keys or call low-level signing helpers directly.

For the full wallet-side state machine and sync rules, see [`05-wallet-architecture.md`](./05-wallet-architecture.md).

## Security notes

This extension is a prototype. The browser storage model is not sufficient for production key custody.

Current security limitations include:

* mnemonic stored in extension local storage;
* relayer private key stored in extension local storage;
* no encryption-at-rest;
* no password-based unlock flow;
* no automatic lock timeout;
* no hardware-backed key protection;
* no secure backup or restore flow;
* no multi-device state coordination;
* no protection against local browser profile compromise;
* no production transaction confirmation UX;
* no dapp origin permission model;
* no injected-provider isolation boundary.

The most important wallet-side invariant is:

```text
Producing a valid signature consumes the corresponding local key immediately.
```

This applies even if:

* the transaction is never broadcast;
* the transaction is dropped;
* the transaction reverts;
* the receipt status is misleading for wallet state;
* the browser closes after signing;
* the account later needs recovery.

Losing local state after signing is dangerous. The wallet may no longer know which derived keys have already produced signatures. A production design must provide a robust state durability, backup, and reconciliation strategy before this model can be used with real assets.

Known open questions:

* How should a production extension encrypt and unlock the mnemonic?
* How should pending signed operations survive browser crashes, service worker restarts, and transaction replacement?
* How should users safely recover from local state loss?
* How should multiple browser profiles or devices coordinate burned signer indices?
* What should the dapp-facing API look like, if this ever becomes more than a local prototype?
* How should arbitrary transaction requests be reviewed and constrained?
* How should extension permissions be reduced or hardened for non-local networks?
* How should the project separate dev-only demo operations from any future wallet UX?

## Related documentation

* [Project README](../README.md)
* [Docs index](./README.md)
* [Wallet architecture](./05-wallet-architecture.md)
* [CLI documentation](./06-cli.md)
* [Quickstart](./00-quickstart.md)
* [Threat model](./02-threat-model.md)
* [Contract documentation](./04-contract.md)


## Where to go next

* [`../README.md`](../README.md): repository entry point and basic commands.
* [`README.md`](./README.md): documentation index.
* [`00-quickstart.md`](./00-quickstart.md): local setup and first run.
* [`01-overview.md`](01-overview.md): conceptual entry point. 
* [`02-threat-model.md`](./02-threat-model.md): threat model, assumptions, and security invariants.
* [`03-architecture.md`](./03-architecture.md): system architecture and trust boundaries.
* [`04-contract.md`](./04-contract.md): Solidity account behavior.
* [`05-wallet-architecture.md`](./05-wallet-architecture.md): TypeScript wallet internals, including key derivation.
* [`06-cli.md`](./06-cli.md): CLI commands and local workflows.
* :pushpin: **[`07-browser-wallet.md`](./07-browser-wallet.md): browser extension prototype.**
* [`08-testing.md`](./08-testing.md): Foundry, Vitest, and local E2E validation.