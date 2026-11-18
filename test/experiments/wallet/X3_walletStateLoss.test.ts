/**
 * X3 (C0-cl-R), lado wallet: pérdida del estado local. Complementa H2 (AFIRMACIONES #24).
 * Usa el SDK real (`OneTimeSignerWallet`) y `reconcileLocalState` real; la lectura on-chain es una instantánea fija.
 * Ejecución: igual que H2 (experimentos/ESPECIFICACION.md §5), desde la réplica de $HOME/exp-run.
 */
import { describe, expect, it } from "vitest";
import type { Address, Hex } from "../../../wallet/node_modules/viem/_types/index.js";
import { OneTimeSignerWallet } from "../../../wallet/src/sdk/OneTimeSignerWallet.js";
import type { OneTimeSignerAccountClientPort, WalletStateStore } from "../../../wallet/src/sdk/ports.js";
import { deriveAuthSigner, deriveRecoverySigner, type DerivationContext } from "../../../wallet/src/crypto/derivation.js";
import { createInitialWalletState, type LocalWalletState } from "../../../wallet/src/protocol/one-time-signer-account/state.js";
import {
  reconcileLocalState,
  SyncInvariantError,
  type OnchainAccountSnapshot,
  type SyncResult,
} from "../../../wallet/src/protocol/one-time-signer-account/sync.js";
import type { Operation, RecoveryOperation } from "../../../wallet/src/protocol/one-time-signer-account/types.js";

const MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const CTX: DerivationContext = {
  mnemonic: MNEMONIC,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};
const TARGET = "0x0000000000000000000000000000000000003000" as Address;

class MemoryStore implements WalletStateStore {
  constructor(public state: LocalWalletState | null) {}
  async load() {
    return this.state;
  }
  async save(s: LocalWalletState) {
    this.state = s;
  }
}

/** Cadena tras 3 operaciones de Alicia: auth[3] vigente; auth[0..3] consumidos; recovery[0] activa. */
class ChainAfter3Ops implements OneTimeSignerAccountClientPort {
  sent = 0;
  consumed = new Set([0, 1, 2, 3].map((i) => deriveAuthSigner(CTX, i).address.toLowerCase()));
  snapshot: OnchainAccountSnapshot = {
    isInitialized: true,
    isPaused: false,
    currentAuthorizedSigner: deriveAuthSigner(CTX, 3).address,
  };
  async sync(state: LocalWalletState): Promise<SyncResult> {
    return reconcileLocalState(state, this.snapshot);
  }
  async readIsConsumedOrReservedSigner(s: Address) {
    return this.consumed.has(s.toLowerCase());
  }
  async readIsActiveRecoverySigner(s: Address) {
    return s.toLowerCase() === deriveRecoverySigner(CTX, 0).address.toLowerCase();
  }
  async executeSignedAndRotate(p: { operation: Operation; signature: Hex }): Promise<Hex> {
    this.sent++;
    this.snapshot = { ...this.snapshot, currentAuthorizedSigner: p.operation.nextAuthorizedSigner };
    return `0x${"aa".repeat(32)}` as Hex;
  }
  async signedRecovery(_p: { recoveryOperation: RecoveryOperation; signature: Hex }): Promise<Hex> {
    this.sent++;
    return `0x${"bb".repeat(32)}` as Hex;
  }
  async waitForReceipt(_h: Hex) {
    return { status: "success" };
  }
}

function stateAt(authIndex: number): LocalWalletState {
  return createInitialWalletState({
    chainId: Number(CTX.chainId),
    delegatedAccount: CTX.delegatedAccount,
    implementationAddress: CTX.implementationAddress,
    walletId: CTX.walletId,
    accountIndex: CTX.accountIndex,
    initialAuthIndex: authIndex,
    initialAuthorizedSigner: deriveAuthSigner(CTX, authIndex).address,
    initialRecoveryIndex: 0,
    initialRecoverySigner: deriveRecoverySigner(CTX, 0).address,
    nowUnix: 1_700_000_000,
  });
}

describe("X3: pérdida del estado local de la wallet (C0-cl-R)", () => {
  it("sin estado: sync, execute y recover lanzan; no se envía nada", async () => {
    const client = new ChainAfter3Ops();
    const wallet = new OneTimeSignerWallet({ mnemonic: MNEMONIC, passphrase: "", store: new MemoryStore(null), client });
    await expect(wallet.sync()).rejects.toThrow("No local wallet state found");
    await expect(wallet.execute({ target: TARGET, data: "0x12345678" })).rejects.toThrow("No local wallet state found");
    await expect(wallet.recover()).rejects.toThrow("No local wallet state found");
    expect(client.sent).toBe(0);
  });

  it("estado recreado desde el índice 0 (flujo createInitialState): sync lanza SyncInvariantError", async () => {
    const client = new ChainAfter3Ops();
    const wallet = new OneTimeSignerWallet({ mnemonic: MNEMONIC, passphrase: "", store: new MemoryStore(stateAt(0)), client });
    await expect(wallet.sync()).rejects.toThrow(SyncInvariantError);
    await expect(wallet.recover()).rejects.toThrow(SyncInvariantError);
    expect(client.sent).toBe(0);
  });

  it("estado recreado a mano con el índice vigente (3), hallado fuera del SDK: vuelve a operar", async () => {
    // El SDK no tiene función para redescubrir el índice; se busca aquí derivando y comparando con la cadena.
    const client = new ChainAfter3Ops();
    let k = -1;
    for (let i = 0; i < 50; i++) {
      if (deriveAuthSigner(CTX, i).address === client.snapshot.currentAuthorizedSigner) { k = i; break; }
    }
    expect(k).toBe(3);
    const store = new MemoryStore(stateAt(k));
    const wallet = new OneTimeSignerWallet({ mnemonic: MNEMONIC, passphrase: "", store, client });
    const r = await wallet.execute({ target: TARGET, data: "0x12345678", deadline: 9_999_999_999n });
    expect(client.sent).toBe(1);
    expect(r.operation.nextAuthorizedSigner).toBe(deriveAuthSigner(CTX, 4).address);
    expect(r.state.status).toBe("READY");
  });
});
