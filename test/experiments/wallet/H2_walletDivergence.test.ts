/**
 * H2 (AFIRMACIONES #24), lado wallet: ¿ofrece la wallet una ruta de salida desde un estado divergente?
 *
 * Usa la lógica real de reconciliación (`reconcileLocalState`, wallet/src/protocol/one-time-signer-account/sync.ts)
 * y el SDK real (`OneTimeSignerWallet`, wallet/src/sdk/OneTimeSignerWallet.ts). Solo se simula la lectura on-chain:
 * el cliente falso devuelve una instantánea fija, igual que haría el adaptador viem (OneTimeSignerAccountClient.ts,
 * l. 193–201, que también delega en reconcileLocalState).
 *
 * Ejecución (fuera de mnt/, ver experimentos/ESPECIFICACION.md §5):
 *   R=$HOME/exp-run/ots; mkdir -p $R/test; ln -sfn $HOME/wallet-vm $R/wallet;
 *   ln -sfn $HOME/wallet-vm/node_modules $R/node_modules; cp -r <proyecto>/ots/test/experiments $R/test/;
 *   cd $R && ./node_modules/.bin/vitest run test/experiments/wallet
 */
import { describe, expect, it } from "vitest";
import type { Address, Hex } from "../../../wallet/node_modules/viem/_types/index.js";
import { OneTimeSignerWallet } from "../../../wallet/src/sdk/OneTimeSignerWallet.js";
import type { OneTimeSignerAccountClientPort, WalletStateStore } from "../../../wallet/src/sdk/ports.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
  type DerivationContext,
} from "../../../wallet/src/crypto/derivation.js";
import {
  createInitialWalletState,
  markPaused,
  type LocalWalletState,
} from "../../../wallet/src/protocol/one-time-signer-account/state.js";
import {
  reconcileLocalState,
  SyncInvariantError,
  type OnchainAccountSnapshot,
  type SyncResult,
} from "../../../wallet/src/protocol/one-time-signer-account/sync.js";
import type { Operation, RecoveryOperation } from "../../../wallet/src/protocol/one-time-signer-account/types.js";

const MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const CTX: DerivationContext = {
  mnemonic: MNEMONIC,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};
const ATTACKER_SIGNER = "0x000000000000000000000000000000000000BaD0" as Address;
const TARGET = "0x0000000000000000000000000000000000003000" as Address;

class MemoryStore implements WalletStateStore {
  constructor(public state: LocalWalletState) {}
  async load() {
    return this.state;
  }
  async save(s: LocalWalletState) {
    this.state = s;
  }
}

/** Cliente con instantánea on-chain fija; sync = reconcileLocalState real. */
class SnapshotClient implements OneTimeSignerAccountClientPort {
  sentOperation = false;
  sentRecovery = false;
  constructor(public snapshot: OnchainAccountSnapshot, public activeRecovery: Set<string>) {}
  async sync(state: LocalWalletState): Promise<SyncResult> {
    return reconcileLocalState(state, this.snapshot);
  }
  async readIsConsumedOrReservedSigner(_s: Address) {
    return false;
  }
  async readIsActiveRecoverySigner(s: Address) {
    return this.activeRecovery.has(s);
  }
  async executeSignedAndRotate(_p: { operation: Operation; signature: Hex }): Promise<Hex> {
    this.sentOperation = true;
    return `0x${"aa".repeat(32)}` as Hex;
  }
  async signedRecovery(p: { recoveryOperation: RecoveryOperation; signature: Hex }): Promise<Hex> {
    this.sentRecovery = true;
    // Efecto on-chain de una recuperación válida (contrato l. 539–549).
    this.snapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: p.recoveryOperation.nextAuthorizedSigner,
      currentRecoverySignerActive: false,
      nextRecoverySignerActive: true,
    };
    return `0x${"bb".repeat(32)}` as Hex;
  }
  async waitForReceipt(_h: Hex) {
    return { status: "success" };
  }
}

const auth0 = deriveAuthSigner(CTX, 0);
const recovery0 = deriveRecoverySigner(CTX, 0);

function readyState(): LocalWalletState {
  return createInitialWalletState({
    chainId: Number(CTX.chainId),
    delegatedAccount: CTX.delegatedAccount,
    implementationAddress: CTX.implementationAddress,
    walletId: CTX.walletId,
    accountIndex: CTX.accountIndex,
    initialAuthIndex: 0,
    initialAuthorizedSigner: auth0.address,
    initialRecoveryIndex: 0,
    initialRecoverySigner: recovery0.address,
    nowUnix: 1_700_000_000,
  });
}

function setup(local: LocalWalletState, snapshot: OnchainAccountSnapshot) {
  const store = new MemoryStore(local);
  const client = new SnapshotClient(snapshot, new Set([recovery0.address]));
  const wallet = new OneTimeSignerWallet({ mnemonic: MNEMONIC, passphrase: "", store, client });
  return { wallet, client, store };
}

/** Lleva el estado local a PENDING_OPERATION con la wallet real (envío simulado, on-chain sin cambios). */
async function pendingAfterSend(): Promise<LocalWalletState> {
  const store = new MemoryStore(readyState());
  const client = new SnapshotClient(
    { isInitialized: true, isPaused: false, currentAuthorizedSigner: auth0.address },
    new Set([recovery0.address]),
  );
  const wallet = new OneTimeSignerWallet({ mnemonic: MNEMONIC, passphrase: "", store, client });
  await wallet.execute({ target: TARGET, data: "0x12345678", deadline: 9_999_999_999n });
  return store.state;
}

const unpausedWith = (signer: Address): OnchainAccountSnapshot => ({
  isInitialized: true,
  isPaused: false,
  currentAuthorizedSigner: signer,
});

describe("H2: ruta de la wallet desde estados divergentes", () => {
  it("control: cuenta pausada on-chain → la wallet recupera", async () => {
    const { wallet, client } = setup(markPaused(readyState()), {
      isInitialized: true,
      isPaused: true,
      currentAuthorizedSigner: auth0.address,
    });
    const r = await wallet.recover({ deadline: 9_999_999_999n });
    expect(client.sentRecovery).toBe(true);
    expect(r.state.status).toBe("READY");
  });

  it("D1: tx de la operación revertida o descartada (H1/H4) → PENDING_OPERATION indefinido, sin ejecutar ni recuperar", async () => {
    const pending = await pendingAfterSend();
    expect(pending.status).toBe("PENDING_OPERATION");
    // on-chain: el firmante sigue siendo el consumido localmente
    const { wallet, client } = setup(pending, unpausedWith(auth0.address));
    const r = await wallet.sync();
    expect(r.reason).toBe("UNCHANGED_PENDING_OPERATION");
    await expect(wallet.execute({ target: TARGET, data: "0x12345678" })).rejects.toThrow(
      "Cannot execute operation while state is PENDING_OPERATION",
    );
    await expect(wallet.recover()).rejects.toThrow("expected PAUSED");
    expect(client.sentOperation || client.sentRecovery).toBe(false);
  });

  it("D2: sucesor del atacante instalado, cuenta activa; local READY → sync lanza, ninguna ruta", async () => {
    const { wallet, client } = setup(readyState(), unpausedWith(ATTACKER_SIGNER));
    await expect(wallet.sync()).rejects.toThrow(SyncInvariantError);
    await expect(wallet.execute({ target: TARGET, data: "0x12345678" })).rejects.toThrow(SyncInvariantError);
    await expect(wallet.recover()).rejects.toThrow(SyncInvariantError);
    expect(client.sentOperation || client.sentRecovery).toBe(false);
  });

  it("D3: sucesor del atacante instalado; local PENDING_OPERATION → sync lanza, ninguna ruta", async () => {
    const pending = await pendingAfterSend();
    const { wallet, client } = setup(pending, unpausedWith(ATTACKER_SIGNER));
    await expect(wallet.recover()).rejects.toThrow(SyncInvariantError);
    await expect(wallet.execute({ target: TARGET, data: "0x12345678" })).rejects.toThrow(SyncInvariantError);
    expect(client.sentRecovery).toBe(false);
  });

  it("D4: edición manual del estado a PAUSED (SAVE_STATE_JSON) con la cuenta activa → sync lanza", async () => {
    const { wallet, client } = setup(markPaused(readyState()), unpausedWith(ATTACKER_SIGNER));
    await expect(wallet.recover()).rejects.toThrow(SyncInvariantError);
    expect(client.sentRecovery).toBe(false);
  });
});
