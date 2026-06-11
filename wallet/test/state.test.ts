import { mkdtemp, readFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { describe, expect, it } from "vitest";
import type { DerivationContext } from "../src/crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../src/crypto/derivation.js";
import type {
  Eip712AccountContext,
  Operation,
  RecoveryOperation,
} from "../src/account/types.js";
import {
  hashOperationTypedData,
  hashRecoveryOperationTypedData,
  signOperation,
  signRecoveryOperation,
} from "../src/account/eip712.js";
import {
  applyOperationAdvanced,
  applyOperationPaused,
  applyRecoveryFailedButConsumed,
  applyRecoverySucceeded,
  attachOperationTxHash,
  attachRecoveryTxHash,
  beginOperationSigning,
  beginRecoverySigning,
  createInitialWalletState,
  markPaused,
  type LocalWalletState,
} from "../src/account/state.js";
import { JsonLocalStore } from "../src/storage/localStore.js";

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

const EIP712_CONTEXT: Eip712AccountContext = {
  chainId: 31337,
  delegatedAccount: DERIVATION_CONTEXT.delegatedAccount,
};

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

describe("LocalWalletState operation state machine", () => {
  it("creates an initial READY state", () => {
    const state = createReadyState();
    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);

    expect(state.status).toBe("READY");
    expect(state.currentAuthIndex).toBe(0);
    expect(state.currentAuthorizedSigner).toBe(auth0.address);
    expect(state.currentRecoveryIndex).toBe(0);
    expect(state.currentRecoverySigner).toBe(recovery0.address);
    expect(state.burnedAuthIndices).toEqual([]);
    expect(state.burnedRecoveryIndices).toEqual([]);
  });

  it("burns current auth signer immediately after signing an operation", async () => {
    const state = createReadyState();

    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9_999_999_999n,
    };

    const signedOperation = await signOperation({
      context: EIP712_CONTEXT,
      operation,
      privateKey: auth0.privateKey,
    });

    const operationDigest = hashOperationTypedData(EIP712_CONTEXT, operation);

    const nextState = beginOperationSigning({
      state,
      signedOperation,
      nextAuthIndex: 1,
      operationDigest,
      signedAtUnix: 1_700_000_001,
    });

    expect(nextState.status).toBe("PENDING_OPERATION");
    expect(nextState.burnedAuthIndices).toEqual([0]);
    expect(nextState.pendingOperation?.consumedAuthIndex).toBe(0);
    expect(nextState.pendingOperation?.consumedAuthSigner).toBe(auth0.address);
    expect(nextState.pendingOperation?.nextAuthIndex).toBe(1);
    expect(nextState.pendingOperation?.nextAuthorizedSigner).toBe(auth1.address);
  });

  it("does not allow signing a second operation while one is pending", async () => {
    const state = createReadyState();

    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9_999_999_999n,
    };

    const signedOperation = await signOperation({
      context: EIP712_CONTEXT,
      operation,
      privateKey: auth0.privateKey,
    });

    const operationDigest = hashOperationTypedData(EIP712_CONTEXT, operation);

    const pendingState = beginOperationSigning({
      state,
      signedOperation,
      nextAuthIndex: 1,
      operationDigest,
    });

    expect(() =>
      beginOperationSigning({
        state: pendingState,
        signedOperation,
        nextAuthIndex: 1,
        operationDigest,
      }),
    ).toThrow("Cannot sign operation while account status is PENDING_OPERATION");
  });

  it("advances to next auth signer after operation is reconciled as advanced", async () => {
    const state = createReadyState();

    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9_999_999_999n,
    };

    const signedOperation = await signOperation({
      context: EIP712_CONTEXT,
      operation,
      privateKey: auth0.privateKey,
    });

    const pendingState = beginOperationSigning({
      state,
      signedOperation,
      nextAuthIndex: 1,
      operationDigest: hashOperationTypedData(EIP712_CONTEXT, operation),
    });

    const advancedState = applyOperationAdvanced(pendingState, 1_700_000_002);

    expect(advancedState.status).toBe("READY");
    expect(advancedState.currentAuthIndex).toBe(1);
    expect(advancedState.currentAuthorizedSigner).toBe(auth1.address);
    expect(advancedState.burnedAuthIndices).toEqual([0]);
    expect(advancedState.pendingOperation).toBeUndefined();
  });

  it("can resolve a pending operation as paused", async () => {
    const state = createReadyState();

    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9_999_999_999n,
    };

    const signedOperation = await signOperation({
      context: EIP712_CONTEXT,
      operation,
      privateKey: auth0.privateKey,
    });

    const pendingState = beginOperationSigning({
      state,
      signedOperation,
      nextAuthIndex: 1,
      operationDigest: hashOperationTypedData(EIP712_CONTEXT, operation),
    });

    const pausedState = applyOperationPaused(pendingState);

    expect(pausedState.status).toBe("PAUSED");
    expect(pausedState.burnedAuthIndices).toEqual([0]);
    expect(pausedState.pendingOperation).toBeUndefined();
  });

  it("can attach a txHash to a pending operation", async () => {
    const state = createReadyState();

    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9_999_999_999n,
    };

    const signedOperation = await signOperation({
      context: EIP712_CONTEXT,
      operation,
      privateKey: auth0.privateKey,
    });

    const pendingState = beginOperationSigning({
      state,
      signedOperation,
      nextAuthIndex: 1,
      operationDigest: hashOperationTypedData(EIP712_CONTEXT, operation),
    });

    const withTxHash = attachOperationTxHash(
      pendingState,
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );

    expect(withTxHash.pendingOperation?.txHash).toBe(
      "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    );
  });
});

describe("LocalWalletState recovery state machine", () => {
  it("does not allow recovery while READY", async () => {
    const state = createReadyState();

    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9_999_999_999n,
    };

    const signedRecoveryOperation = await signRecoveryOperation({
      context: EIP712_CONTEXT,
      recoveryOperation,
      privateKey: recovery0.privateKey,
    });

    expect(() =>
      beginRecoverySigning({
        state,
        signedRecoveryOperation,
        nextAuthIndex: 10,
        nextRecoveryIndex: 1,
        recoveryDigest: hashRecoveryOperationTypedData(
          EIP712_CONTEXT,
          recoveryOperation,
        ),
      }),
    ).toThrow("Cannot sign recovery while account status is READY");
  });

  it("burns current recovery signer immediately after signing recovery", async () => {
    const readyState = createReadyState();
    const pausedState = markPaused(readyState);

    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9_999_999_999n,
    };

    const signedRecoveryOperation = await signRecoveryOperation({
      context: EIP712_CONTEXT,
      recoveryOperation,
      privateKey: recovery0.privateKey,
    });

    const recoveryDigest = hashRecoveryOperationTypedData(
      EIP712_CONTEXT,
      recoveryOperation,
    );

    const pendingRecoveryState = beginRecoverySigning({
      state: pausedState,
      signedRecoveryOperation,
      nextAuthIndex: 10,
      nextRecoveryIndex: 1,
      recoveryDigest,
      signedAtUnix: 1_700_000_003,
    });

    expect(pendingRecoveryState.status).toBe("PENDING_RECOVERY");
    expect(pendingRecoveryState.burnedRecoveryIndices).toEqual([0]);
    expect(pendingRecoveryState.pendingRecovery?.consumedRecoveryIndex).toBe(0);
    expect(pendingRecoveryState.pendingRecovery?.consumedRecoverySigner).toBe(
      recovery0.address,
    );
    expect(pendingRecoveryState.pendingRecovery?.nextAuthIndex).toBe(10);
    expect(pendingRecoveryState.pendingRecovery?.nextAuthorizedSigner).toBe(
      auth10.address,
    );
    expect(pendingRecoveryState.pendingRecovery?.nextRecoveryIndex).toBe(1);
    expect(pendingRecoveryState.pendingRecovery?.nextRecoverySigner).toBe(
      recovery1.address,
    );
  });

  it("applies successful recovery and returns to READY", async () => {
    const readyState = createReadyState();
    const pausedState = markPaused(readyState);

    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9_999_999_999n,
    };

    const signedRecoveryOperation = await signRecoveryOperation({
      context: EIP712_CONTEXT,
      recoveryOperation,
      privateKey: recovery0.privateKey,
    });

    const pendingRecoveryState = beginRecoverySigning({
      state: pausedState,
      signedRecoveryOperation,
      nextAuthIndex: 10,
      nextRecoveryIndex: 1,
      recoveryDigest: hashRecoveryOperationTypedData(
        EIP712_CONTEXT,
        recoveryOperation,
      ),
    });

    const recoveredState = applyRecoverySucceeded(pendingRecoveryState);

    expect(recoveredState.status).toBe("READY");
    expect(recoveredState.currentAuthIndex).toBe(10);
    expect(recoveredState.currentAuthorizedSigner).toBe(auth10.address);
    expect(recoveredState.currentRecoveryIndex).toBe(1);
    expect(recoveredState.currentRecoverySigner).toBe(recovery1.address);
    expect(recoveredState.burnedRecoveryIndices).toEqual([0]);
    expect(recoveredState.pendingRecovery).toBeUndefined();
  });

  it("can resolve failed recovery as consumed and paused", async () => {
    const readyState = createReadyState();
    const pausedState = markPaused(readyState);

    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9_999_999_999n,
    };

    const signedRecoveryOperation = await signRecoveryOperation({
      context: EIP712_CONTEXT,
      recoveryOperation,
      privateKey: recovery0.privateKey,
    });

    const pendingRecoveryState = beginRecoverySigning({
      state: pausedState,
      signedRecoveryOperation,
      nextAuthIndex: 10,
      nextRecoveryIndex: 1,
      recoveryDigest: hashRecoveryOperationTypedData(
        EIP712_CONTEXT,
        recoveryOperation,
      ),
    });

    const failedState = applyRecoveryFailedButConsumed(pendingRecoveryState);

    expect(failedState.status).toBe("PAUSED");
    expect(failedState.burnedRecoveryIndices).toEqual([0]);
    expect(failedState.pendingRecovery).toBeUndefined();
  });

  it("can attach a txHash to a pending recovery", async () => {
    const readyState = createReadyState();
    const pausedState = markPaused(readyState);

    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9_999_999_999n,
    };

    const signedRecoveryOperation = await signRecoveryOperation({
      context: EIP712_CONTEXT,
      recoveryOperation,
      privateKey: recovery0.privateKey,
    });

    const pendingRecoveryState = beginRecoverySigning({
      state: pausedState,
      signedRecoveryOperation,
      nextAuthIndex: 10,
      nextRecoveryIndex: 1,
      recoveryDigest: hashRecoveryOperationTypedData(
        EIP712_CONTEXT,
        recoveryOperation,
      ),
    });

    const withTxHash = attachRecoveryTxHash(
      pendingRecoveryState,
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );

    expect(withTxHash.pendingRecovery?.txHash).toBe(
      "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    );
  });
});

describe("JsonLocalStore", () => {
  it("saves and loads LocalWalletState", async () => {
    const dir = await mkdtemp(join(tmpdir(), "ephemeral-wallet-"));
    const path = join(dir, "state.json");

    try {
      const store = new JsonLocalStore(path);
      const state = createReadyState();

      await store.save(state);

      const raw = await readFile(path, "utf8");
      expect(raw).toContain('"status": "READY"');

      const loaded = await store.load();

      expect(loaded).toEqual(state);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  it("returns null when state file does not exist", async () => {
    const dir = await mkdtemp(join(tmpdir(), "ephemeral-wallet-"));
    const path = join(dir, "missing.json");

    try {
      const store = new JsonLocalStore(path);
      const loaded = await store.load();

      expect(loaded).toBeNull();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});