/**
 * Core SDK types.
 *
 * The browser wallet will use these interfaces instead of importing CLI scripts.
 * The core only requires a small storage adapter and an account-client adapter,
 * which makes it portable across Node, browser extensions and tests.
 */
import type { Address, Hex } from "viem";
import type { DerivationContext } from "../crypto/derivation.js";
import type { LocalWalletState } from "../account/state.js";
import type { Operation, RecoveryOperation, SignedOperation, SignedRecoveryOperation } from "../account/types.js";
import type { SyncResult } from "../account/sync.js";

export type WalletStateStore = {
  load(): Promise<LocalWalletState | null>;
  save(state: LocalWalletState): Promise<void>;
};

export type AccountClientLike = {
  sync(state: LocalWalletState): Promise<SyncResult>;

  readIsConsumedOrReservedSigner(signer: Address): Promise<boolean>;
  readIsActiveRecoverySigner(signer: Address): Promise<boolean>;

  executeSignedAndRotate(params: {
    operation: Operation;
    signature: Hex;
  }): Promise<Hex>;

  signedRecovery(params: {
    recoveryOperation: RecoveryOperation;
    signature: Hex;
  }): Promise<Hex>;

  waitForReceipt(txHash: Hex): Promise<unknown>;
};

export type EphemeralWalletConfig = {
  mnemonic: string;
  passphrase?: string;
  store: WalletStateStore;
  client: AccountClientLike;
};

export type ExecuteParams = {
  target: Address;
  data: Hex;
  value?: bigint;
  deadline?: bigint;
  deadlineSeconds?: number;
  maxLookahead?: number;
};

export type ExecuteResult = {
  operation: Operation;
  signedOperation: SignedOperation;
  operationDigest: Hex;
  txHash: Hex;
  receipt: unknown;
  syncResult: SyncResult;
  state: LocalWalletState;
};

export type RecoverParams = {
  deadline?: bigint;
  deadlineSeconds?: number;
  authLookahead?: number;
  recoveryLookahead?: number;
};

export type RecoverResult = {
  recoveryOperation: RecoveryOperation;
  signedRecoveryOperation: SignedRecoveryOperation;
  recoveryDigest: Hex;
  txHash: Hex;
  receipt: unknown;
  syncResult: SyncResult;
  state: LocalWalletState;
};

export type WalletSnapshot = {
  state: LocalWalletState;
  derivationContext: DerivationContext;
};
