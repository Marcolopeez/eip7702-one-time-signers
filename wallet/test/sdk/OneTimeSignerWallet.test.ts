import { describe, expect, it } from "vitest";
import type { Address, Hex } from "viem";
import { getAddress } from "viem";
import { OneTimeSignerWallet } from "../../src/sdk/OneTimeSignerWallet.js";
import type { OneTimeSignerAccountClientPort, WalletStateStore } from "../../src/sdk/ports.js";
import type { DerivationContext } from "../../src/crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../../src/crypto/derivation.js";
import {
  applyOperationAdvanced,
  applyRecoverySucceeded,
  createInitialWalletState,
  markPaused,
  type LocalWalletState,
} from "../../src/protocol/one-time-signer-account/state.js";
import type { Operation, RecoveryOperation } from "../../src/protocol/one-time-signer-account/types.js";
import type { SyncResult } from "../../src/protocol/one-time-signer-account/sync.js";

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

const DERIVATION_CONTEXT: DerivationContext = {
  mnemonic: TEST_MNEMONIC,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};

class MemoryStore implements WalletStateStore {
  state: LocalWalletState | null;
  readonly history: LocalWalletState[] = [];

  constructor(initialState: LocalWalletState) {
    this.state = initialState;
  }

  async load(): Promise<LocalWalletState | null> {
    return this.state;
  }

  async save(state: LocalWalletState): Promise<void> {
    this.state = state;
    this.history.push(state);
  }
}

class FakeAccountClient implements OneTimeSignerAccountClientPort {
  readonly activeRecoverySigners = new Set<string>();
  readonly consumedOrReservedSigners = new Set<string>();

  lastOperation?: Operation;
  lastRecoveryOperation?: RecoveryOperation;
  lastOperationSignature?: Hex;
  lastRecoverySignature?: Hex;

  async sync(state: LocalWalletState): Promise<SyncResult> {
    if (state.status === "READY") {
      return {
        state,
        changed: false,
        reason: "UNCHANGED_READY",
        snapshot: {
          isInitialized: true,
          isPaused: false,
          currentAuthorizedSigner: state.currentAuthorizedSigner,
        },
      };
    }

    if (state.status === "PAUSED") {
      return {
        state,
        changed: false,
        reason: "UNCHANGED_PAUSED",
        snapshot: {
          isInitialized: true,
          isPaused: true,
          currentAuthorizedSigner: state.currentAuthorizedSigner,
        },
      };
    }

    if (state.status === "PENDING_OPERATION") {
      if (!state.pendingOperation) {
        throw new Error("test invariant: missing pendingOperation");
      }

      return {
        state: applyOperationAdvanced(state),
        changed: true,
        reason: "PENDING_OPERATION_TO_READY",
        snapshot: {
          isInitialized: true,
          isPaused: false,
          currentAuthorizedSigner: state.pendingOperation.nextAuthorizedSigner,
        },
      };
    }

    if (!state.pendingRecovery) {
      throw new Error("test invariant: missing pendingRecovery");
    }

    return {
      state: applyRecoverySucceeded(state),
      changed: true,
      reason: "PENDING_RECOVERY_TO_READY",
      snapshot: {
        isInitialized: true,
        isPaused: false,
        currentAuthorizedSigner: state.pendingRecovery.nextAuthorizedSigner,
        currentRecoverySignerActive: false,
        nextRecoverySignerActive: true,
      },
    };
  }

  async readIsConsumedOrReservedSigner(signer: Address): Promise<boolean> {
    return this.consumedOrReservedSigners.has(getAddress(signer));
  }

  async readIsActiveRecoverySigner(signer: Address): Promise<boolean> {
    return this.activeRecoverySigners.has(getAddress(signer));
  }

  async executeSignedAndRotate(params: {
    operation: Operation;
    signature: Hex;
  }): Promise<Hex> {
    this.lastOperation = params.operation;
    this.lastOperationSignature = params.signature;
    return "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
  }

  async signedRecovery(params: {
    recoveryOperation: RecoveryOperation;
    signature: Hex;
  }): Promise<Hex> {
    this.lastRecoveryOperation = params.recoveryOperation;
    this.lastRecoverySignature = params.signature;
    return "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
  }

  async waitForReceipt(_txHash: Hex): Promise<unknown> {
    return {
      status: "success",
      blockNumber: 1n,
    };
  }
}

function createReadyState(): LocalWalletState {
  const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
  const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);

  return createInitialWalletState({
    chainId: Number(DERIVATION_CONTEXT.chainId),
    delegatedAccount: DERIVATION_CONTEXT.delegatedAccount,
    implementationAddress: DERIVATION_CONTEXT.implementationAddress,
    walletId: DERIVATION_CONTEXT.walletId,
    accountIndex: DERIVATION_CONTEXT.accountIndex,
    initialAuthIndex: 0,
    initialAuthorizedSigner: auth0.address,
    initialRecoveryIndex: 0,
    initialRecoverySigner: recovery0.address,
    nowUnix: 1_700_000_000,
  });
}

function createWallet(params?: { paused?: boolean }) {
  const readyState = createReadyState();
  const initialState = params?.paused ? markPaused(readyState) : readyState;
  const store = new MemoryStore(initialState);
  const client = new FakeAccountClient();

  const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
  client.activeRecoverySigners.add(recovery0.address);

  const wallet = new OneTimeSignerWallet({
    mnemonic: TEST_MNEMONIC,
    passphrase: "",
    store,
    client,
  });

  return { wallet, store, client };
}

describe("OneTimeSignerWallet core SDK", () => {
  it("executes through the safe operation flow and persists pending before final sync", async () => {
    const { wallet, store, client } = createWallet();
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const result = await wallet.execute({
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      deadline: 9_999_999_999n,
    });

    expect(client.lastOperation).toBeDefined();
    expect(client.lastOperation?.nextAuthorizedSigner).toBe(auth1.address);
    expect(client.lastOperationSignature).toBeDefined();

    expect(store.history.some((state) => state.status === "PENDING_OPERATION")).toBe(true);
    expect(result.syncResult.reason).toBe("PENDING_OPERATION_TO_READY");
    expect(result.state.status).toBe("READY");
    expect(result.state.currentAuthIndex).toBe(1);
    expect(result.state.currentAuthorizedSigner).toBe(auth1.address);
    expect(result.state.burnedAuthIndices).toEqual([0]);
  });

  it("does not execute while paused", async () => {
    const { wallet, client } = createWallet({ paused: true });

    await expect(
      wallet.execute({
        target: "0x0000000000000000000000000000000000003000",
        data: "0x12345678",
      }),
    ).rejects.toThrow("Cannot execute operation while state is PAUSED");

    expect(client.lastOperation).toBeUndefined();
  });

  it("recovers a paused account and rotates both auth and recovery streams", async () => {
    const { wallet, store, client } = createWallet({ paused: true });
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);

    const result = await wallet.recover({ deadline: 9_999_999_999n });

    expect(client.lastRecoveryOperation).toBeDefined();
    expect(client.lastRecoveryOperation?.nextAuthorizedSigner).toBe(auth1.address);
    expect(client.lastRecoveryOperation?.nextRecoverySigner).toBe(recovery1.address);
    expect(client.lastRecoverySignature).toBeDefined();

    expect(store.history.some((state) => state.status === "PENDING_RECOVERY")).toBe(true);
    expect(result.syncResult.reason).toBe("PENDING_RECOVERY_TO_READY");
    expect(result.state.status).toBe("READY");
    expect(result.state.currentAuthIndex).toBe(1);
    expect(result.state.currentAuthorizedSigner).toBe(auth1.address);
    expect(result.state.currentRecoveryIndex).toBe(1);
    expect(result.state.currentRecoverySigner).toBe(recovery1.address);
    expect(result.state.burnedRecoveryIndices).toEqual([0]);
  });
});
