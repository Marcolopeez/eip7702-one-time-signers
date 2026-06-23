import { useEffect, useMemo, useState } from "react";
import { browser } from "wxt/browser";
import { ActionSummary,
  ExtensionRequest,
  ExtensionResponse,
  ExtensionSnapshot,
  ExtensionWalletSettings,
} from "../../src/extension/types.js";

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

export default function App() {
  const [snapshot, setSnapshot] = useState<ExtensionSnapshot | null>(null);
  const [mnemonic, setMnemonic] = useState("");
  const [passphrase, setPassphrase] = useState("");
  const [rpcUrl, setRpcUrl] = useState(DEFAULT_RPC_URL);
  const [relayerPrivateKey, setRelayerPrivateKey] = useState("");
  const [executionTargetAddress, setExecutionTargetAddress] = useState("");
  const [stateJson, setStateJson] = useState("");
  const [newNumber, setNewNumber] = useState("2026");
  const [lastAction, setLastAction] = useState<ActionSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function refresh() {
    const nextSnapshot = await send<ExtensionSnapshot>({ type: "GET_SNAPSHOT" });
    setSnapshot(nextSnapshot);

    if (nextSnapshot.settings) {
      setRpcUrl(nextSnapshot.settings.rpcUrl);
      setExecutionTargetAddress(nextSnapshot.settings.executionTargetAddress ?? "");
    }

    if (nextSnapshot.state) {
      setStateJson(JSON.stringify(nextSnapshot.state, null, 2));
    }
  }

  async function runAction<T>(fn: () => Promise<T>): Promise<T | undefined> {
    setBusy(true);
    setError(null);

    try {
      const result = await fn();
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

  async function saveConfiguration() {
    const settings: ExtensionWalletSettings = {
      mnemonic,
      ...(passphrase !== "" ? { passphrase } : {}),
      rpcUrl,
      relayerPrivateKey: relayerPrivateKey as `0x${string}`,
      ...(executionTargetAddress !== ""
        ? { executionTargetAddress: executionTargetAddress as `0x${string}` }
        : {}),
    };

    await runAction(async () => {
      const data = await send<ExtensionSnapshot>({
        type: "SAVE_SETTINGS",
        settings,
        ...(stateJson.trim() !== "" ? { stateJson } : {}),
      });
      setSnapshot(data);
    });
  }

  async function sync() {
    await runAction(async () => {
      const result = await send<ActionSummary>({ type: "SYNC" });
      setLastAction(result);
    });
  }

  async function executeSetNumber() {
    await runAction(async () => {
      const result = await send<ActionSummary>({
        type: "EXECUTE_SET_NUMBER",
        newNumber,
      });
      setLastAction(result);
    });
  }

  async function recover() {
    await runAction(async () => {
      const result = await send<ActionSummary>({ type: "RECOVER" });
      setLastAction(result);
    });
  }

  async function clearAll() {
    await runAction(async () => {
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
          <h1>Ephemeral Key Wallet</h1>
          <p>EIP-7702 one-time-key prototype</p>
        </div>
        <span className={statusClass}>{state?.status ?? "UNCONFIGURED"}</span>
      </header>

      <section className="warning">
        Experimental local-dev wallet. Do not use a real mnemonic or real funds.
        The prototype stores configuration in extension local storage.
      </section>

      <section className="card">
        <h2>State</h2>
        <dl className="grid">
          <dt>Delegated account</dt>
          <dd title={state?.delegatedAccount}>{shortAddress(state?.delegatedAccount)}</dd>
          <dt>Auth index</dt>
          <dd>{state?.currentAuthIndex ?? "—"}</dd>
          <dt>Auth signer</dt>
          <dd title={state?.currentAuthorizedSigner}>{shortAddress(state?.currentAuthorizedSigner)}</dd>
          <dt>Recovery index</dt>
          <dd>{state?.currentRecoveryIndex ?? "—"}</dd>
          <dt>Recovery signer</dt>
          <dd title={state?.currentRecoverySigner}>{shortAddress(state?.currentRecoverySigner)}</dd>
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
            <dd title={lastAction.txHash}>{lastAction.txHash ? shortAddress(lastAction.txHash) : "—"}</dd>
            <dt>sync reason</dt>
            <dd>{lastAction.syncReason ?? "—"}</dd>
            <dt>status</dt>
            <dd>{lastAction.status ?? "—"}</dd>
          </dl>
        </section>
      )}

      <section className="card">
        <h2>Configuration</h2>
        <label>
          Mnemonic
          <textarea value={mnemonic} onChange={(event) => setMnemonic(event.target.value)} />
        </label>
        <label>
          Passphrase optional
          <input value={passphrase} onChange={(event) => setPassphrase(event.target.value)} />
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
            placeholder="0x..."
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
        <label>
          LocalWalletState JSON
          <textarea
            className="stateJson"
            value={stateJson}
            onChange={(event) => setStateJson(event.target.value)}
          />
        </label>
        <div className="row">
          <button onClick={saveConfiguration} disabled={busy}>
            Save configuration
          </button>
          <button className="secondary" onClick={clearAll} disabled={busy}>
            Clear
          </button>
        </div>
      </section>

      {error && <section className="error">{error}</section>}
    </main>
  );
}
