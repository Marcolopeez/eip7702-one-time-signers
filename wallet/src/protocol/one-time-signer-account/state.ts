/**
 * Local wallet state machine.
 *
 * This module enforces the wallet-side rule that producing a signature consumes
 * the corresponding one-time key, even before a transaction is broadcast or
 * mined. It does not perform RPC reads; later sync code reconciles these states
 * with the contract.
 */
import { getAddress, type Address, type Hex } from "viem";
import type {
  SignedOperation,
  SignedRecoveryOperation,
} from "./types.js";

/**
 * High-level lifecycle of the delegated account from the wallet perspective.
 */
export type AccountStatus =
  | "READY"
  | "PENDING_OPERATION"
  | "PAUSED"
  | "PENDING_RECOVERY";

/**
 * Operation that has already been signed with the current auth key.
 *
 * The consumed key must never be used again, regardless of the final on-chain
 * result of this operation.
 */
export type PendingOperation = {
  consumedAuthIndex: number;
  consumedAuthSigner: Address;

  nextAuthIndex: number;
  nextAuthorizedSigner: Address;

  operationDigest: Hex;
  signature: Hex;

  signedAtUnix: number;
  txHash?: Hex;
};

/**
 * Recovery operation that has already been signed with the current recovery key.
 */
export type PendingRecovery = {
  consumedRecoveryIndex: number;
  consumedRecoverySigner: Address;

  nextAuthIndex: number;
  nextAuthorizedSigner: Address;

  nextRecoveryIndex: number;
  nextRecoverySigner: Address;

  recoveryDigest: Hex;
  signature: Hex;

  signedAtUnix: number;
  txHash?: Hex;
};

/**
 * Persisted state for one delegated account.
 *
 * burned*Indices are part of the security model, not merely UI history. They
 * prevent accidental reuse of keys after a signature has left the wallet.
 */
export type LocalWalletState = {
  schemaVersion: 1;

  chainId: number;
  delegatedAccount: Address;
  implementationAddress: Address;
  walletId: Hex;
  accountIndex: number;

  status: AccountStatus;

  currentAuthIndex: number;
  currentAuthorizedSigner: Address;

  currentRecoveryIndex: number;
  currentRecoverySigner: Address;

  burnedAuthIndices: number[];
  burnedRecoveryIndices: number[];

  pendingOperation?: PendingOperation;
  pendingRecovery?: PendingRecovery;

  updatedAtUnix: number;
};

export type CreateInitialWalletStateParams = {
  chainId: number;
  delegatedAccount: Address;
  implementationAddress: Address;
  walletId: Hex;
  accountIndex: number;

  initialAuthIndex: number;
  initialAuthorizedSigner: Address;

  initialRecoveryIndex: number;
  initialRecoverySigner: Address;

  nowUnix?: number;
};

export type BeginOperationSigningParams = {
  state: LocalWalletState;
  signedOperation: SignedOperation;
  nextAuthIndex: number;
  operationDigest: Hex;
  signedAtUnix?: number;
};

export type BeginUnsafeOperationSigningForPauseTestParams = {
  state: LocalWalletState;
  signedOperation: SignedOperation;
  nextAuthIndex: number;
  operationDigest: Hex;
  signedAtUnix?: number;

  /**
   * Required string so call sites have to document why they are using
   * this unsafe transition.
   */
  devOnlyReason: string;
};

export type BeginRecoverySigningParams = {
  state: LocalWalletState;
  signedRecoveryOperation: SignedRecoveryOperation;
  nextAuthIndex: number;
  nextRecoveryIndex: number;
  recoveryDigest: Hex;
  signedAtUnix?: number;
};

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

function nowUnix(): number {
  return Math.floor(Date.now() / 1000);
}

function normalizeAddress(address: Address): Address {
  return getAddress(address);
}

function assertPositiveChainId(chainId: number): void {
  if (!Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new Error("chainId must be a positive safe integer");
  }
}

function assertSafeIndex(index: number, label: string): void {
  if (!Number.isInteger(index)) {
    throw new Error(`${label} must be an integer`);
  }

  if (index < 0) {
    throw new Error(`${label} must be non-negative`);
  }

  if (index >= 2 ** 31) {
    throw new Error(`${label} must be lower than 2^31`);
  }
}

function assertNonZeroAddress(address: Address, label: string): void {
  if (normalizeAddress(address) === ZERO_ADDRESS) {
    throw new Error(`${label} cannot be zero address`);
  }
}

function assertSameAddress(actual: Address, expected: Address, label: string): void {
  if (normalizeAddress(actual) !== normalizeAddress(expected)) {
    throw new Error(
      `${label} mismatch: expected ${normalizeAddress(expected)}, got ${normalizeAddress(actual)}`,
    );
  }
}

function hasIndex(indices: number[], index: number): boolean {
  return indices.includes(index);
}

function addBurnedIndex(indices: number[], index: number): number[] {
  if (indices.includes(index)) {
    return indices;
  }

  return [...indices, index].sort((a, b) => a - b);
}

function assertIndexNotBurned(indices: number[], index: number, label: string): void {
  if (hasIndex(indices, index)) {
    throw new Error(`${label} ${index} is already burned`);
  }
}

/**
 * Creates the initial local state after the delegated account is initialized.
 */
export function createInitialWalletState(
  params: CreateInitialWalletStateParams,
): LocalWalletState {
  assertPositiveChainId(params.chainId);
  assertSafeIndex(params.accountIndex, "accountIndex");
  assertSafeIndex(params.initialAuthIndex, "initialAuthIndex");
  assertSafeIndex(params.initialRecoveryIndex, "initialRecoveryIndex");

  assertNonZeroAddress(params.delegatedAccount, "delegatedAccount");
  assertNonZeroAddress(params.implementationAddress, "implementationAddress");
  assertNonZeroAddress(params.initialAuthorizedSigner, "initialAuthorizedSigner");
  assertNonZeroAddress(params.initialRecoverySigner, "initialRecoverySigner");

  return {
    schemaVersion: 1,

    chainId: params.chainId,
    delegatedAccount: normalizeAddress(params.delegatedAccount),
    implementationAddress: normalizeAddress(params.implementationAddress),
    walletId: params.walletId,
    accountIndex: params.accountIndex,

    status: "READY",

    currentAuthIndex: params.initialAuthIndex,
    currentAuthorizedSigner: normalizeAddress(params.initialAuthorizedSigner),

    currentRecoveryIndex: params.initialRecoveryIndex,
    currentRecoverySigner: normalizeAddress(params.initialRecoverySigner),

    burnedAuthIndices: [],
    burnedRecoveryIndices: [],

    updatedAtUnix: params.nowUnix ?? nowUnix(),
  };
}

/**
 * Checks whether the wallet may produce a normal operation signature.
 */
export function assertCanSignOperation(state: LocalWalletState): void {
  if (state.status !== "READY") {
    throw new Error(`Cannot sign operation while account status is ${state.status}`);
  }

  if (state.pendingOperation) {
    throw new Error("Cannot sign operation while another operation is pending");
  }

  if (state.pendingRecovery) {
    throw new Error("Cannot sign operation while recovery is pending");
  }

  assertIndexNotBurned(
    state.burnedAuthIndices,
    state.currentAuthIndex,
    "currentAuthIndex",
  );
}

/**
 * Checks whether the wallet may produce a recovery signature.
 *
 * Recovery is intentionally restricted to PAUSED accounts in this prototype.
 */
export function assertCanSignRecovery(state: LocalWalletState): void {
  if (state.status !== "PAUSED") {
    throw new Error(`Cannot sign recovery while account status is ${state.status}`);
  }

  if (state.pendingOperation) {
    throw new Error("Cannot sign recovery while operation is pending");
  }

  if (state.pendingRecovery) {
    throw new Error("Cannot sign recovery while another recovery is pending");
  }

  assertIndexNotBurned(
    state.burnedRecoveryIndices,
    state.currentRecoveryIndex,
    "currentRecoveryIndex",
  );
}

/**
 * Records that an Operation signature has been produced.
 *
 * This is the security boundary: the current auth key is burned before any
 * transaction receipt exists, because the signature itself may expose the key
 * under the post-quantum threat model.
 */
export function beginOperationSigning(
  params: BeginOperationSigningParams,
): LocalWalletState {
  const { state, signedOperation, nextAuthIndex, operationDigest } = params;

  assertCanSignOperation(state);

  assertSafeIndex(nextAuthIndex, "nextAuthIndex");
  assertIndexNotBurned(state.burnedAuthIndices, nextAuthIndex, "nextAuthIndex");

  assertSameAddress(
    signedOperation.signer,
    state.currentAuthorizedSigner,
    "operation signer",
  );

  const nextAuthorizedSigner = normalizeAddress(
    signedOperation.operation.nextAuthorizedSigner,
  );

  assertNonZeroAddress(nextAuthorizedSigner, "nextAuthorizedSigner");

  if (nextAuthIndex === state.currentAuthIndex) {
    throw new Error("nextAuthIndex cannot equal currentAuthIndex");
  }

  if (nextAuthorizedSigner === state.currentAuthorizedSigner) {
    throw new Error("nextAuthorizedSigner cannot equal currentAuthorizedSigner");
  }

  return {
    ...state,
    status: "PENDING_OPERATION",
    burnedAuthIndices: addBurnedIndex(
      state.burnedAuthIndices,
      state.currentAuthIndex,
    ),
    pendingOperation: {
      consumedAuthIndex: state.currentAuthIndex,
      consumedAuthSigner: state.currentAuthorizedSigner,

      nextAuthIndex,
      nextAuthorizedSigner,

      operationDigest,
      signature: signedOperation.signature,

      signedAtUnix: params.signedAtUnix ?? nowUnix(),
    },
    updatedAtUnix: params.signedAtUnix ?? nowUnix(),
  };
}

/**
 * Adds the broadcast transaction hash to an already signed operation.
 */
export function attachOperationTxHash(
  state: LocalWalletState,
  txHash: Hex,
  now: number = nowUnix(),
): LocalWalletState {
  if (state.status !== "PENDING_OPERATION" || !state.pendingOperation) {
    throw new Error("No pending operation to attach txHash to");
  }

  return {
    ...state,
    pendingOperation: {
      ...state.pendingOperation,
      txHash,
    },
    updatedAtUnix: now,
  };
}

/**
 * Applies a successful on-chain rotation after sync observes the expected signer.
 */
export function applyOperationAdvanced(
  state: LocalWalletState,
  now: number = nowUnix(),
): LocalWalletState {
  if (state.status !== "PENDING_OPERATION" || !state.pendingOperation) {
    throw new Error("No pending operation to advance");
  }

  const pending = state.pendingOperation;
  const { pendingOperation: _pendingOperation, ...stateWithoutPending } = state;

  return {
    ...stateWithoutPending,
    status: "READY",
    currentAuthIndex: pending.nextAuthIndex,
    currentAuthorizedSigner: pending.nextAuthorizedSigner,
    updatedAtUnix: now,
  };
}

/**
 * Resolves a signed operation as leaving the account paused.
 *
 * The consumed auth key remains burned even though normal execution did not
 * resume. Recovery is the only safe path forward from this state.
 */
export function applyOperationPaused(
  state: LocalWalletState,
  now: number = nowUnix(),
): LocalWalletState {
  if (state.status !== "PENDING_OPERATION" || !state.pendingOperation) {
    throw new Error("No pending operation to resolve as paused");
  }

  const { pendingOperation: _pendingOperation, ...stateWithoutPending } = state;

  return {
    ...stateWithoutPending,
    status: "PAUSED",
    updatedAtUnix: now,
  };
}

/**
 * Forces the local account into PAUSED mode after sync observes the contract
 * emergency state.
 */
export function markPaused(
  state: LocalWalletState,
  now: number = nowUnix(),
): LocalWalletState {
  const {
    pendingOperation: _pendingOperation,
    pendingRecovery: _pendingRecovery,
    ...stateWithoutPending
  } = state;

  return {
    ...stateWithoutPending,
    status: "PAUSED",
    updatedAtUnix: now,
  };
}

/**
 * Records that a RecoveryOperation signature has been produced.
 *
 * The recovery key is burned immediately for the same reason as auth keys: a
 * valid ECDSA signature is treated as exposure of that one-time key.
 */
export function beginRecoverySigning(
  params: BeginRecoverySigningParams,
): LocalWalletState {
  const {
    state,
    signedRecoveryOperation,
    nextAuthIndex,
    nextRecoveryIndex,
    recoveryDigest,
  } = params;

  assertCanSignRecovery(state);

  assertSafeIndex(nextAuthIndex, "nextAuthIndex");
  assertSafeIndex(nextRecoveryIndex, "nextRecoveryIndex");

  assertIndexNotBurned(state.burnedAuthIndices, nextAuthIndex, "nextAuthIndex");
  assertIndexNotBurned(
    state.burnedRecoveryIndices,
    nextRecoveryIndex,
    "nextRecoveryIndex",
  );

  assertSameAddress(
    signedRecoveryOperation.signer,
    state.currentRecoverySigner,
    "recovery signer",
  );

  const nextAuthorizedSigner = normalizeAddress(
    signedRecoveryOperation.recoveryOperation.nextAuthorizedSigner,
  );

  const nextRecoverySigner = normalizeAddress(
    signedRecoveryOperation.recoveryOperation.nextRecoverySigner,
  );

  assertNonZeroAddress(nextAuthorizedSigner, "nextAuthorizedSigner");
  assertNonZeroAddress(nextRecoverySigner, "nextRecoverySigner");

  if (nextRecoveryIndex === state.currentRecoveryIndex) {
    throw new Error("nextRecoveryIndex cannot equal currentRecoveryIndex");
  }

  if (nextRecoverySigner === state.currentRecoverySigner) {
    throw new Error("nextRecoverySigner cannot equal currentRecoverySigner");
  }

  return {
    ...state,
    status: "PENDING_RECOVERY",
    burnedRecoveryIndices: addBurnedIndex(
      state.burnedRecoveryIndices,
      state.currentRecoveryIndex,
    ),
    pendingRecovery: {
      consumedRecoveryIndex: state.currentRecoveryIndex,
      consumedRecoverySigner: state.currentRecoverySigner,

      nextAuthIndex,
      nextAuthorizedSigner,

      nextRecoveryIndex,
      nextRecoverySigner,

      recoveryDigest,
      signature: signedRecoveryOperation.signature,

      signedAtUnix: params.signedAtUnix ?? nowUnix(),
    },
    updatedAtUnix: params.signedAtUnix ?? nowUnix(),
  };
}

/**
 * Adds the broadcast transaction hash to an already signed recovery.
 */
export function attachRecoveryTxHash(
  state: LocalWalletState,
  txHash: Hex,
  now: number = nowUnix(),
): LocalWalletState {
  if (state.status !== "PENDING_RECOVERY" || !state.pendingRecovery) {
    throw new Error("No pending recovery to attach txHash to");
  }

  return {
    ...state,
    pendingRecovery: {
      ...state.pendingRecovery,
      txHash,
    },
    updatedAtUnix: now,
  };
}

/**
 * Applies a successful recovery after sync observes both expected new signers.
 */
export function applyRecoverySucceeded(
  state: LocalWalletState,
  now: number = nowUnix(),
): LocalWalletState {
  if (state.status !== "PENDING_RECOVERY" || !state.pendingRecovery) {
    throw new Error("No pending recovery to apply");
  }

  const pending = state.pendingRecovery;
  const { pendingRecovery: _pendingRecovery, ...stateWithoutPending } = state;

  return {
    ...stateWithoutPending,
    status: "READY",

    currentAuthIndex: pending.nextAuthIndex,
    currentAuthorizedSigner: pending.nextAuthorizedSigner,

    currentRecoveryIndex: pending.nextRecoveryIndex,
    currentRecoverySigner: pending.nextRecoverySigner,

    updatedAtUnix: now,
  };
}

/**
 * Resolves a recovery attempt that consumed the recovery key but did not restore
 * the account to READY.
 */
export function applyRecoveryFailedButConsumed(
  state: LocalWalletState,
  now: number = nowUnix(),
): LocalWalletState {
  if (state.status !== "PENDING_RECOVERY" || !state.pendingRecovery) {
    throw new Error("No pending recovery to resolve as failed");
  }

  const { pendingRecovery: _pendingRecovery, ...stateWithoutPending } = state;

  return {
    ...stateWithoutPending,
    status: "PAUSED",
    updatedAtUnix: now,
  };
}

export function beginUnsafeOperationSigningForPauseTest(
  params: BeginUnsafeOperationSigningForPauseTestParams,
): LocalWalletState {
  const {
    state,
    signedOperation,
    nextAuthIndex,
    operationDigest,
    devOnlyReason,
  } = params;

  if (!devOnlyReason.includes("DEV_ONLY")) {
    throw new Error(
      "beginUnsafeOperationSigningForPauseTest requires a DEV_ONLY reason",
    );
  }

  assertCanSignOperation(state);
  assertSafeIndex(nextAuthIndex, "nextAuthIndex");

  assertSameAddress(
    signedOperation.signer,
    state.currentAuthorizedSigner,
    "operation signer",
  );

  /**
   * Intentionally DO NOT validate nextAuthorizedSigner here.
   *
   * This function exists only to test the contract's emergency pause path
   * when a valid signature contains an invalid nextAuthorizedSigner.
   *
   * Production wallet flows must use beginOperationSigning().
   */
  const nextAuthorizedSigner = normalizeAddress(
    signedOperation.operation.nextAuthorizedSigner,
  );

  return {
    ...state,
    status: "PENDING_OPERATION",
    burnedAuthIndices: addBurnedIndex(
      state.burnedAuthIndices,
      state.currentAuthIndex,
    ),
    pendingOperation: {
      consumedAuthIndex: state.currentAuthIndex,
      consumedAuthSigner: state.currentAuthorizedSigner,

      nextAuthIndex,
      nextAuthorizedSigner,

      operationDigest,
      signature: signedOperation.signature,

      signedAtUnix: params.signedAtUnix ?? nowUnix(),
    },
    updatedAtUnix: params.signedAtUnix ?? nowUnix(),
  };
}
