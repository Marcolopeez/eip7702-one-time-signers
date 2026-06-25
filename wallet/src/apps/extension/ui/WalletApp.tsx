import { useEffect, useMemo, useState } from "react";
import { browser } from "wxt/browser";
import type {
  ActionSummary,
  ExtensionRequest,
  ExtensionResponse,
  ExtensionSnapshot,
  ExtensionWalletSettingsInput,
} from "../messaging/types.js";
import {
  parseLocalWalletStateJson,
  validateSettingsInput,
} from "../config/validation.js";

const DEFAULT_RPC_URL = "http://127.0.0.1:8545";

async function send<T>(message: ExtensionRequest): Promise<T> {
  const response = (await browser.runtime.sendMessage(message)) as ExtensionResponse<T>;

  if (!response.ok) {
    throw new Error(response.error);
  }

  return response.data;
}

function shortAddress(value?: string): string {
  if (!value) return "—";
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

function stringifyState(snapshot: ExtensionSnapshot | null): string {
  return snapshot?.state ? JSON.stringify(snapshot.state, null, 2) : "";
}

function downloadText(filename: string, text: string): void {
  const blob = new Blob([text], { type: "application/json" });
  const url = URL.createObjectURL(blob);

  try {
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    anchor.click();
  } finally {
    URL.revokeObjectURL(url);
  }
}

export type WalletAppProps = {
  mode: "popup" | "dashboard";
};

export default function WalletApp(props: WalletAppProps) {
  const [snapshot, setSnapshot] = useState<ExtensionSnapshot | null>(null);

  const [mnemonic, setMnemonic] = useState("");
  const [passphrase, setPassphrase] = useState("");
  const [rpcUrl, setRpcUrl] = useState(DEFAULT_RPC_URL);
  const [relayerPrivateKey, setRelayerPrivateKey] = useState("");
  const [executionTargetAddress, setExecutionTargetAddress] = useState("");

  const [stateJson, setStateJson] = useState("");
  const [newNumber, setNewNumber] = useState("2026");

  const [lastAction, setLastAction] = useState<ActionSummary | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function refresh(options?: { overwriteStateEditor?: boolean }) {
    const nextSnapshot = await send<ExtensionSnapshot>({ type: "GET_SNAPSHOT" });
    setSnapshot(nextSnapshot);

    if (nextSnapshot.settings) {
      setRpcUrl(nextSnapshot.settings.rpcUrl);
      setExecutionTargetAddress(nextSnapshot.settings.executionTargetAddress ?? "");
    }

    if (options?.overwriteStateEditor ?? true) {
      setStateJson(stringifyState(nextSnapshot));
    }
  }

  async function openDashboard() {
    await browser.runtime.openOptionsPage();
  }

  async function runAction<T>(
    label: string,
    fn: () => Promise<T>,
  ): Promise<T | undefined> {
    setBusy(true);
    setError(null);
    setNotice(null);

    try {
      const result = await fn();
      setNotice(label);
      await refresh();
      return result;
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
      return undefined;
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    refresh().catch((err) => setError(err instanceof Error ? err.message : String(err)));
  }, []);

  const state = snapshot?.state;
  const canExecute = state?.status === "READY";
  const canRecover = state?.status === "PAUSED";

  const statusClass = useMemo(() => {
    if (!state) return "badge muted";
    if (state.status === "READY") return "badge ok";
    if (state.status === "PAUSED") return "badge danger";
    return "badge warn";
  }, [state]);

  const stateValidation = useMemo(() => {
    if (stateJson.trim() === "") return null;
    return parseLocalWalletStateJson(stateJson);
  }, [stateJson]);

  async function saveSettings() {
    const settingsInput: ExtensionWalletSettingsInput = {
      rpcUrl,
      ...(mnemonic.trim() !== "" ? { mnemonic } : {}),
      ...(passphrase !== "" ? { passphrase } : {}),
      ...(relayerPrivateKey.trim() !== ""
        ? { relayerPrivateKey: relayerPrivateKey as `0x${string}` }
        : {}),
      ...(executionTargetAddress.trim() !== ""
        ? { executionTargetAddress: executionTargetAddress as `0x${string}` }
        : {}),
    };

    const validation = validateSettingsInput(
      settingsInput,
      snapshot?.hasSettings
        ? {
            mnemonic: "already-stored-placeholder",
            rpcUrl: snapshot.settings?.rpcUrl ?? DEFAULT_RPC_URL,
            relayerPrivateKey:
              "0x0000000000000000000000000000000000000000000000000000000000000001",
            ...(snapshot.settings?.executionTargetAddress
              ? { executionTargetAddress: snapshot.settings.executionTargetAddress }
              : {}),
          }
        : null,
    );

    if (!validation.ok) {
      setError(validation.error);
      return;
    }

    await runAction("Settings saved", async () => {
      const data = await send<ExtensionSnapshot>({
        type: "SAVE_SETTINGS",
        settings: settingsInput,
      });

      setSnapshot(data);
      setMnemonic("");
      setRelayerPrivateKey("");
    });
  }

  async function importState() {
    if (!stateValidation?.ok) {
      setError(stateValidation?.error ?? "State JSON is empty");
      return;
    }

    await runAction("State imported", async () => {
      const data = await send<ExtensionSnapshot>({
        type: "SAVE_STATE_JSON",
        stateJson,
      });

      setSnapshot(data);
    });
  }

  async function saveSettingsAndState() {
    if (stateJson.trim() === "") {
      await saveSettings();
      return;
    }

    if (!stateValidation?.ok) {
      setError(stateValidation?.error ?? "State JSON is invalid");
      return;
    }

    const settingsInput: ExtensionWalletSettingsInput = {
      rpcUrl,
      ...(mnemonic.trim() !== "" ? { mnemonic } : {}),
      ...(passphrase !== "" ? { passphrase } : {}),
      ...(relayerPrivateKey.trim() !== ""
        ? { relayerPrivateKey: relayerPrivateKey as `0x${string}` }
        : {}),
      ...(executionTargetAddress.trim() !== ""
        ? { executionTargetAddress: executionTargetAddress as `0x${string}` }
        : {}),
    };

    await runAction("Settings and state saved", async () => {
      const data = await send<ExtensionSnapshot>({
        type: "SAVE_SETTINGS",
        settings: settingsInput,
        stateJson,
      });

      setSnapshot(data);
      setMnemonic("");
      setRelayerPrivateKey("");
    });
  }

  async function sync() {
    await runAction("Sync completed", async () => {
      const result = await send<ActionSummary>({ type: "SYNC" });
      setLastAction(result);
    });
  }

  async function executeSetNumber() {
    await runAction("setNumber executed", async () => {
      const result = await send<ActionSummary>({
        type: "EXECUTE_SET_NUMBER",
        newNumber,
      });
      setLastAction(result);
    });
  }

  async function recover() {
    await runAction("Recovery completed", async () => {
      const result = await send<ActionSummary>({ type: "RECOVER" });
      setLastAction(result);
    });
  }

  async function copyState() {
    const currentStateJson = stringifyState(snapshot);

    if (currentStateJson === "") {
      setError("No state available to copy");
      return;
    }

    await navigator.clipboard.writeText(currentStateJson);
    setNotice("State copied to clipboard");
  }

  function downloadState() {
    const currentStateJson = stringifyState(snapshot);

    if (currentStateJson === "") {
      setError("No state available to download");
      return;
    }

    downloadText("one-time-signer-wallet-state.json", currentStateJson);
    setNotice("State downloaded");
  }

  async function clearAll() {
    await runAction("Extension storage cleared", async () => {
      await send<ExtensionSnapshot>({ type: "CLEAR_ALL" });
      setMnemonic("");
      setPassphrase("");
      setRpcUrl(DEFAULT_RPC_URL);
      setRelayerPrivateKey("");
      setExecutionTargetAddress("");
      setStateJson("");
      setLastAction(null);
    });
  }

  return (
    <main className="shell">
      <header className="header">
        <div>
          <h1>One-Time Signer Wallet</h1>
          <p>EIP-7702 one-time-key prototype</p>
        </div>
        <span className={statusClass}>{state?.status ?? "UNCONFIGURED"}</span>
      </header>

      {props.mode === "popup" && (
        <section className="card compact">
          <p>
            Open the dashboard for a persistent
            demo view.
          </p>
          <div className="row">
            <button onClick={openDashboard} disabled={busy}>
              Open dashboard
            </button>
          </div>
        </section>
      )}

      <section className="warning">
        Experimental local-dev wallet. Do not use a real mnemonic or real funds.
        Secrets are currently stored in extension local storage.
      </section>

      {notice && <section className="notice">{notice}</section>}
      {error && <section className="error">{error}</section>}

      <section className="card">
        <h2>Account state</h2>
        <dl className="grid">
          <dt>Delegated account</dt>
          <dd title={state?.delegatedAccount}>{shortAddress(state?.delegatedAccount)}</dd>

          <dt>Auth index</dt>
          <dd>{state?.currentAuthIndex ?? "—"}</dd>

          <dt>Auth signer</dt>
          <dd title={state?.currentAuthorizedSigner}>
            {shortAddress(state?.currentAuthorizedSigner)}
          </dd>

          <dt>Recovery index</dt>
          <dd>{state?.currentRecoveryIndex ?? "—"}</dd>

          <dt>Recovery signer</dt>
          <dd title={state?.currentRecoverySigner}>
            {shortAddress(state?.currentRecoverySigner)}
          </dd>
        </dl>

        <div className="row">
          <button onClick={sync} disabled={busy || !snapshot?.hasSettings || !snapshot?.hasState}>
            Sync
          </button>
          <button onClick={executeSetNumber} disabled={busy || !canExecute}>
            Execute setNumber
          </button>
          <button onClick={recover} disabled={busy || !canRecover}>
            Recover
          </button>
        </div>

        <label className="inlineLabel">
          setNumber value
          <input value={newNumber} onChange={(event) => setNewNumber(event.target.value)} />
        </label>
      </section>

      {lastAction && (
        <section className="card">
          <h2>Last action</h2>
          <dl className="grid">
            <dt>txHash</dt>
            <dd title={lastAction.txHash}>
              {lastAction.txHash ? shortAddress(lastAction.txHash) : "—"}
            </dd>

            <dt>sync reason</dt>
            <dd>{lastAction.syncReason ?? "—"}</dd>

            <dt>status</dt>
            <dd>{lastAction.status ?? "—"}</dd>

            <dt>auth index</dt>
            <dd>{lastAction.currentAuthIndex ?? "—"}</dd>

            <dt>recovery index</dt>
            <dd>{lastAction.currentRecoveryIndex ?? "—"}</dd>
          </dl>
        </section>
      )}

      <section className="card">
        <h2>Configuration</h2>

        <div className="miniGrid">
          <span>Mnemonic</span>
          <strong>{snapshot?.settings?.mnemonicConfigured ? "stored" : "missing"}</strong>

          <span>Relayer</span>
          <strong>{snapshot?.settings?.relayerConfigured ? "stored" : "missing"}</strong>

          <span>Passphrase</span>
          <strong>{snapshot?.settings?.passphraseConfigured ? "stored" : "not set"}</strong>
        </div>

        <label>
          Mnemonic
          <textarea
            value={mnemonic}
            onChange={(event) => setMnemonic(event.target.value)}
            placeholder={
              snapshot?.settings?.mnemonicConfigured
                ? "Already stored. Leave empty to keep it."
                : "Enter development mnemonic"
            }
          />
        </label>

        <label>
          Passphrase optional
          <input
            value={passphrase}
            onChange={(event) => setPassphrase(event.target.value)}
            placeholder={
              snapshot?.settings?.passphraseConfigured
                ? "Already stored. Leave empty to keep it."
                : "Optional"
            }
          />
        </label>

        <label>
          RPC URL
          <input value={rpcUrl} onChange={(event) => setRpcUrl(event.target.value)} />
        </label>

        <label>
          Relayer private key
          <input
            value={relayerPrivateKey}
            onChange={(event) => setRelayerPrivateKey(event.target.value)}
            placeholder={
              snapshot?.settings?.relayerConfigured
                ? "Already stored. Leave empty to keep it."
                : "0x..."
            }
          />
        </label>

        <label>
          ExecutionTarget address
          <input
            value={executionTargetAddress}
            onChange={(event) => setExecutionTargetAddress(event.target.value)}
            placeholder="0x..."
          />
        </label>

        <div className="row">
          <button onClick={saveSettings} disabled={busy}>
            Save settings
          </button>
          <button onClick={saveSettingsAndState} disabled={busy}>
            Save settings + state
          </button>
          <button className="secondary" onClick={clearAll} disabled={busy}>
            Clear
          </button>
        </div>
      </section>

      <section className="card">
        <h2>State import / export</h2>

        <label>
          LocalWalletState JSON
          <textarea
            className="stateJson"
            value={stateJson}
            onChange={(event) => setStateJson(event.target.value)}
            placeholder="Paste wallet/.local/state.json here"
          />
        </label>

        {stateJson.trim() !== "" && (
          <p className={stateValidation?.ok ? "validation okText" : "validation errorText"}>
            {stateValidation?.ok ? "State JSON looks valid" : stateValidation?.error}
          </p>
        )}

        <div className="row">
          <button onClick={importState} disabled={busy || !stateValidation?.ok}>
            Import state
          </button>
          <button className="secondary" onClick={copyState} disabled={busy || !snapshot?.hasState}>
            Copy current state
          </button>
          <button className="secondary" onClick={downloadState} disabled={busy || !snapshot?.hasState}>
            Download state
          </button>
        </div>
      </section>
    </main>
  );
}