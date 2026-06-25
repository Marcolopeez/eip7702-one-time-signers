/**
 * High-level wallet SDK.
 *
 * This class is the boundary the browser extension should call. It keeps the
 * security-critical sequence in one place:
 *
 *   sync -> derive -> sign -> burn locally -> persist -> broadcast -> sync
 *
 * UI code must not call low-level signing helpers directly.
 */
import { getAddress, type Address, type Hex } from "viem";
import { deriveAuthSigner, deriveRecoverySigner, type DerivationContext } from "../crypto/derivation.js";
import {
  hashOperationTypedData,
  hashRecoveryOperationTypedData,
  signOperation,
  signRecoveryOperation,
} from "../protocol/one-time-signer-account/eip712.js";
import {
  attachOperationTxHash,
  attachRecoveryTxHash,
  beginOperationSigning,
  beginRecoverySigning,
  type LocalWalletState,
} from "../protocol/one-time-signer-account/state.js";
import type { Operation, RecoveryOperation } from "../protocol/one-time-signer-account/types.js";
import type { SyncResult } from "../protocol/one-time-signer-account/sync.js";
import {
  findNextAvailableRecoverySigner,
  findNextUnusedAuthSigner,
} from "../protocol/one-time-signer-account/signerSelection.js";
import type {
  OneTimeSignerAccountClientPort,
  WalletStateStore,
} from "./ports.js";
import type {
  OneTimeSignerWalletConfig,
  ExecuteParams,
  ExecuteResult,
  RecoverParams,
  RecoverResult,
} from "./types.js";

const DEFAULT_DEADLINE_SECONDS = 3600;
const DEFAULT_LOOKAHEAD = 50;

function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

function makeDeadline(params: {
  deadline?: bigint;
  deadlineSeconds?: number;
}): bigint {
  if (params.deadline !== undefined) {
    return params.deadline;
  }

  const deadlineSeconds = params.deadlineSeconds ?? DEFAULT_DEADLINE_SECONDS;

  if (!Number.isSafeInteger(deadlineSeconds)) {
    throw new Error("deadlineSeconds must be a safe integer");
  }

  return BigInt(nowSeconds() + deadlineSeconds);
}

function assertSameAddress(actual: Address, expected: Address, label: string): void {
  if (getAddress(actual) !== getAddress(expected)) {
    throw new Error(
      `${label} mismatch: expected ${getAddress(expected)}, got ${getAddress(actual)}`,
    );
  }
}

export class OneTimeSignerWallet {
  readonly mnemonic: string;
  readonly passphrase?: string;
  readonly store: WalletStateStore;
  readonly client: OneTimeSignerAccountClientPort;

  constructor(config: OneTimeSignerWalletConfig) {
    this.mnemonic = config.mnemonic;

    if (config.passphrase !== undefined) {
      this.passphrase = config.passphrase;
    }

    this.store = config.store;
    this.client = config.client;
  }


  async getState(): Promise<LocalWalletState> {
    return this.loadStateOrThrow();
  }

  async sync(): Promise<SyncResult> {
    const state = await this.loadStateOrThrow();
    const result = await this.client.sync(state);

    if (result.changed) {
      await this.store.save(result.state);
    }

    return result;
  }

  async execute(params: ExecuteParams): Promise<ExecuteResult> {
    const syncResult = await this.sync();
    let state = syncResult.state;

    if (state.status !== "READY") {
      throw new Error(`Cannot execute operation while state is ${state.status}`);
    }

    const derivationContext = this.buildDerivationContext(state);
    const currentAuthSigner = deriveAuthSigner(
      derivationContext,
      state.currentAuthIndex,
    );

    assertSameAddress(
      currentAuthSigner.address,
      state.currentAuthorizedSigner,
      "derived current auth signer",
    );

    const nextAuthSigner = await findNextUnusedAuthSigner({
      context: derivationContext,
      startIndex: state.currentAuthIndex + 1,
      reader: this.client,
      maxLookahead: params.maxLookahead ?? DEFAULT_LOOKAHEAD,
      localBurnedIndices: state.burnedAuthIndices,
    });

    const operation: Operation = {
      target: getAddress(params.target),
      value: params.value ?? 0n,
      data: params.data,
      nextAuthorizedSigner: nextAuthSigner.address,
      deadline: makeDeadline(params),
    };

    const eip712Context = this.buildEip712Context(state);

    const signedOperation = await signOperation({
      context: eip712Context,
      operation,
      privateKey: currentAuthSigner.privateKey,
    });

    const operationDigest = hashOperationTypedData(eip712Context, operation);

    /**
     * Security boundary: once this returns, auth[currentAuthIndex] is burned
     * locally and the new state must be persisted before broadcast.
     */
    state = beginOperationSigning({
      state,
      signedOperation,
      nextAuthIndex: nextAuthSigner.index,
      operationDigest,
    });

    await this.store.save(state);

    const txHash = await this.client.executeSignedAndRotate({
      operation,
      signature: signedOperation.signature,
    });

    state = attachOperationTxHash(state, txHash);
    await this.store.save(state);

    const receipt = await this.client.waitForReceipt(txHash);

    const afterSync = await this.client.sync(state);
    await this.store.save(afterSync.state);

    return {
      operation,
      signedOperation,
      operationDigest,
      txHash,
      receipt,
      syncResult: afterSync,
      state: afterSync.state,
    };
  }

  async recover(params: RecoverParams = {}): Promise<RecoverResult> {
    const syncResult = await this.sync();
    let state = syncResult.state;

    if (state.status !== "PAUSED") {
      throw new Error(`Cannot recover while state is ${state.status}; expected PAUSED`);
    }

    const derivationContext = this.buildDerivationContext(state);
    const currentRecoverySigner = deriveRecoverySigner(
      derivationContext,
      state.currentRecoveryIndex,
    );

    assertSameAddress(
      currentRecoverySigner.address,
      state.currentRecoverySigner,
      "derived current recovery signer",
    );

    const currentRecoverySignerActive = await this.client.readIsActiveRecoverySigner(
      currentRecoverySigner.address,
    );

    if (!currentRecoverySignerActive) {
      throw new Error(
        `Current recovery signer ${currentRecoverySigner.address} is not active on-chain`,
      );
    }

    const nextAuthSigner = await findNextUnusedAuthSigner({
      context: derivationContext,
      startIndex: state.currentAuthIndex + 1,
      reader: this.client,
      maxLookahead: params.authLookahead ?? DEFAULT_LOOKAHEAD,
      localBurnedIndices: state.burnedAuthIndices,
    });

    const nextRecoverySigner = await findNextAvailableRecoverySigner({
      context: derivationContext,
      startIndex: state.currentRecoveryIndex + 1,
      reader: this.client,
      maxLookahead: params.recoveryLookahead ?? DEFAULT_LOOKAHEAD,
      localBurnedIndices: state.burnedRecoveryIndices,
    });

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: nextAuthSigner.address,
      nextRecoverySigner: nextRecoverySigner.address,
      deadline: makeDeadline(params),
    };

    const eip712Context = this.buildEip712Context(state);

    const signedRecoveryOperation = await signRecoveryOperation({
      context: eip712Context,
      recoveryOperation,
      privateKey: currentRecoverySigner.privateKey,
    });

    const recoveryDigest = hashRecoveryOperationTypedData(
      eip712Context,
      recoveryOperation,
    );

    /**
     * Security boundary: recovery[currentRecoveryIndex] is burned locally before
     * the recovery transaction is broadcast.
     */
    state = beginRecoverySigning({
      state,
      signedRecoveryOperation,
      nextAuthIndex: nextAuthSigner.index,
      nextRecoveryIndex: nextRecoverySigner.index,
      recoveryDigest,
    });

    await this.store.save(state);

    const txHash = await this.client.signedRecovery({
      recoveryOperation,
      signature: signedRecoveryOperation.signature,
    });

    state = attachRecoveryTxHash(state, txHash);
    await this.store.save(state);

    const receipt = await this.client.waitForReceipt(txHash);

    const afterSync = await this.client.sync(state);
    await this.store.save(afterSync.state);

    return {
      recoveryOperation,
      signedRecoveryOperation,
      recoveryDigest,
      txHash,
      receipt,
      syncResult: afterSync,
      state: afterSync.state,
    };
  }

  private async loadStateOrThrow(): Promise<LocalWalletState> {
    const state = await this.store.load();

    if (!state) {
      throw new Error("No local wallet state found");
    }

    return state;
  }

  private buildEip712Context(state: LocalWalletState) {
    return {
      chainId: state.chainId,
      delegatedAccount: state.delegatedAccount,
    };
  }

  private buildDerivationContext(state: LocalWalletState): DerivationContext {
    const context: DerivationContext = {
      mnemonic: this.mnemonic,
      walletId: state.walletId,
      chainId: state.chainId,
      delegatedAccount: state.delegatedAccount,
      implementationAddress: state.implementationAddress,
      accountIndex: state.accountIndex,
    };

    if (this.passphrase !== undefined) {
      context.passphrase = this.passphrase;
    }

    return context;
  }
}
