/**
 * SDK ports.
 *
 * These are the external capabilities required by OneTimeSignerWallet.
 *
 * The SDK should not know whether state is stored in:
 * - a JSON file,
 * - browser.storage.local,
 * - IndexedDB,
 * - memory in tests,
 * - or something else.
 *
 * Likewise, it should not know whether Ethereum access is implemented through:
 * - viem,
 * - a mock client,
 * - a future RPC abstraction,
 * - or a remote relayer service.
 */
import type { Address, Hex } from "viem";
import type {
  Operation,
  RecoveryOperation,
} from "../protocol/one-time-signer-account/types.js";
import type { LocalWalletState } from "../protocol/one-time-signer-account/state.js";
import type { SyncResult } from "../protocol/one-time-signer-account/sync.js";

/**
 * Persistence boundary for the wallet local state.
 *
 * Critical invariant:
 * after signing, the SDK must be able to persist the burned/pending state
 * before broadcasting the transaction.
 */
export type WalletStateStore = {
  load(): Promise<LocalWalletState | null>;
  save(state: LocalWalletState): Promise<void>;
};

/**
 * Read capability needed to decide whether a derived signer is safe to use.
 *
 * Auth signers must not be reused if they are already consumed or reserved.
 */
export type SignerReservationReader = {
  readIsConsumedOrReservedSigner(signer: Address): Promise<boolean>;
};

/**
 * Read capability needed for recovery signer checks.
 *
 * Recovery signers are one-time keys too, so the wallet needs to know whether
 * a recovery signer is currently active on-chain.
 */
export type RecoverySignerReader = {
  readIsActiveRecoverySigner(signer: Address): Promise<boolean>;
};

/**
 * Combined key-status reader used by signer selection.
 */
export type SignerStatusReader = SignerReservationReader & RecoverySignerReader;

/**
 * Sync capability.
 *
 * The source of truth after a transaction is not the receipt, but on-chain
 * delegated-account storage reconciled against local state.
 */
export type AccountSyncPort = {
  sync(state: LocalWalletState): Promise<SyncResult>;
};

/**
 * Write capability for submitting already-signed operations.
 *
 * The auth/recovery keys do not pay gas here. They only produce EIP-712
 * signatures. This port represents the relayed Ethereum transaction layer.
 */
export type AccountTxPort = {
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

/**
 * Full account client required by OneTimeSignerWallet.
 *
 * The viem implementation should implement this port, but the SDK should depend
 * only on this interface.
 */
export type OneTimeSignerAccountClientPort =
  & AccountSyncPort
  & SignerStatusReader
  & AccountTxPort;