import { describe, expect, it } from "vitest";
import type { DerivationContext } from "../../src/crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../../src/crypto/derivation.js";
import type {
  Eip712AccountContext,
  Operation,
  RecoveryOperation,
} from "../../src/protocol/one-time-signer-account/types.js";
import {
  hashOperationTypedData,
  hashRecoveryOperationTypedData,
  signOperation,
  signRecoveryOperation,
} from "../../src/protocol/one-time-signer-account/eip712.js";
import {
  beginOperationSigning,
  beginRecoverySigning,
  createInitialWalletState,
  markPaused,
  type LocalWalletState,
} from "../../src/protocol/one-time-signer-account/state.js";
import {
  reconcileLocalState,
  SyncInvariantError,
  type OnchainAccountSnapshot,
} from "../../src/protocol/one-time-signer-account/sync.js";

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

async function createPendingOperationState(): Promise<LocalWalletState> {
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

  return beginOperationSigning({
    state,
    signedOperation,
    nextAuthIndex: 1,
    operationDigest: hashOperationTypedData(EIP712_CONTEXT, operation),
    signedAtUnix: 1_700_000_001,
  });
}

async function createPendingRecoveryState(): Promise<LocalWalletState> {
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

  return beginRecoverySigning({
    state: pausedState,
    signedRecoveryOperation,
    nextAuthIndex: 10,
    nextRecoveryIndex: 1,
    recoveryDigest: hashRecoveryOperationTypedData(
      EIP712_CONTEXT,
      recoveryOperation,
    ),
    signedAtUnix: 1_700_000_002,
  });
}

describe("reconcileLocalState - READY", () => {
  it("keeps READY unchanged when on-chain state matches", () => {
    const state = createReadyState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: state.currentAuthorizedSigner,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(false);
    expect(result.reason).toBe("UNCHANGED_READY");
    expect(result.state).toEqual(state);
  });

  it("moves READY to PAUSED when on-chain account is paused", () => {
    const state = createReadyState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: true,
      currentAuthorizedSigner: state.currentAuthorizedSigner,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(true);
    expect(result.reason).toBe("READY_TO_PAUSED");
    expect(result.state.status).toBe("PAUSED");
  });

  it("throws when READY signer differs from on-chain signer", () => {
    const state = createReadyState();
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: auth1.address,
    };

    expect(() => reconcileLocalState(state, snapshot)).toThrow(
      SyncInvariantError,
    );
  });
});

describe("reconcileLocalState - PENDING_OPERATION", () => {
  it("keeps PENDING_OPERATION while tx has not advanced on-chain", async () => {
    const state = await createPendingOperationState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: state.pendingOperation!.consumedAuthSigner,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(false);
    expect(result.reason).toBe("UNCHANGED_PENDING_OPERATION");
    expect(result.state.status).toBe("PENDING_OPERATION");
  });

  it("moves PENDING_OPERATION to READY when signer advanced", async () => {
    const state = await createPendingOperationState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: state.pendingOperation!.nextAuthorizedSigner,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(true);
    expect(result.reason).toBe("PENDING_OPERATION_TO_READY");
    expect(result.state.status).toBe("READY");
    expect(result.state.currentAuthIndex).toBe(
      state.pendingOperation!.nextAuthIndex,
    );
    expect(result.state.currentAuthorizedSigner).toBe(
      state.pendingOperation!.nextAuthorizedSigner,
    );
  });

  it("moves PENDING_OPERATION to PAUSED when account paused", async () => {
    const state = await createPendingOperationState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: true,
      currentAuthorizedSigner: state.pendingOperation!.consumedAuthSigner,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(true);
    expect(result.reason).toBe("PENDING_OPERATION_TO_PAUSED");
    expect(result.state.status).toBe("PAUSED");
    expect(result.state.pendingOperation).toBeUndefined();
  });
});

describe("reconcileLocalState - PAUSED", () => {
  it("keeps PAUSED unchanged while on-chain account is paused", () => {
    const readyState = createReadyState();
    const pausedState = markPaused(readyState);

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: true,
      currentAuthorizedSigner: pausedState.currentAuthorizedSigner,
    };

    const result = reconcileLocalState(pausedState, snapshot);

    expect(result.changed).toBe(false);
    expect(result.reason).toBe("UNCHANGED_PAUSED");
    expect(result.state.status).toBe("PAUSED");
  });
});

describe("reconcileLocalState - PENDING_RECOVERY", () => {
  it("keeps PENDING_RECOVERY while recovery tx has not landed", async () => {
    const state = await createPendingRecoveryState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: true,
      currentAuthorizedSigner: state.currentAuthorizedSigner,
      currentRecoverySignerActive: true,
      nextRecoverySignerActive: false,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(false);
    expect(result.reason).toBe("UNCHANGED_PENDING_RECOVERY");
    expect(result.state.status).toBe("PENDING_RECOVERY");
  });

  it("moves PENDING_RECOVERY to PAUSED when recovery key was consumed but recovery failed", async () => {
    const state = await createPendingRecoveryState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: true,
      currentAuthorizedSigner: state.currentAuthorizedSigner,
      currentRecoverySignerActive: false,
      nextRecoverySignerActive: false,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(true);
    expect(result.reason).toBe("PENDING_RECOVERY_TO_PAUSED");
    expect(result.state.status).toBe("PAUSED");
    expect(result.state.pendingRecovery).toBeUndefined();
  });

  it("moves PENDING_RECOVERY to READY when recovery fully succeeded", async () => {
    const state = await createPendingRecoveryState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: state.pendingRecovery!.nextAuthorizedSigner,
      currentRecoverySignerActive: false,
      nextRecoverySignerActive: true,
    };

    const result = reconcileLocalState(state, snapshot);

    expect(result.changed).toBe(true);
    expect(result.reason).toBe("PENDING_RECOVERY_TO_READY");
    expect(result.state.status).toBe("READY");
    expect(result.state.currentAuthIndex).toBe(
      state.pendingRecovery!.nextAuthIndex,
    );
    expect(result.state.currentAuthorizedSigner).toBe(
      state.pendingRecovery!.nextAuthorizedSigner,
    );
    expect(result.state.currentRecoveryIndex).toBe(
      state.pendingRecovery!.nextRecoveryIndex,
    );
    expect(result.state.currentRecoverySigner).toBe(
      state.pendingRecovery!.nextRecoverySigner,
    );
  });

  it("throws on critical partial recovery", async () => {
    const state = await createPendingRecoveryState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: true,
      isPaused: false,
      currentAuthorizedSigner: state.pendingRecovery!.nextAuthorizedSigner,
      currentRecoverySignerActive: false,
      nextRecoverySignerActive: false,
    };

    expect(() => reconcileLocalState(state, snapshot)).toThrow(
      "Critical partial recovery",
    );
  });
});

describe("reconcileLocalState - initialization", () => {
  it("throws if delegated account is not initialized on-chain", () => {
    const state = createReadyState();

    const snapshot: OnchainAccountSnapshot = {
      isInitialized: false,
      isPaused: false,
      currentAuthorizedSigner: state.currentAuthorizedSigner,
    };

    expect(() => reconcileLocalState(state, snapshot)).toThrow(
      "Delegated account is not initialized on-chain",
    );
  });
});