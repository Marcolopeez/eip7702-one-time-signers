/**
 * Public SDK types.
 *
 * These types describe the API exposed by OneTimeSignerWallet.
 *
 * Low-level ports live in ports.ts.
 */
import type { Address, Hex } from "viem";
import type { DerivationContext } from "../crypto/derivation.js";
import type {
  Operation,
  RecoveryOperation,
  SignedOperation,
  SignedRecoveryOperation,
} from "../protocol/one-time-signer-account/types.js";
import type { LocalWalletState } from "../protocol/one-time-signer-account/state.js";
import type { SyncResult } from "../protocol/one-time-signer-account/sync.js";
import type {
  OneTimeSignerAccountClientPort,
  WalletStateStore,
} from "./ports.js";

/**
 * Construction config for the high-level wallet SDK.
 *
 * The mnemonic/passphrase are used locally to derive auth/recovery keys.
 * The store persists local wallet state.
 * The client reads/writes delegated-account state on-chain.
 */
export type OneTimeSignerWalletConfig = {
  mnemonic: string;
  passphrase?: string;
  store: WalletStateStore;
  client: OneTimeSignerAccountClientPort;
};

/**
 * Parameters for a normal signed operation.
 *
 * The SDK will:
 * - sync first,
 * - derive the current auth signer,
 * - select a fresh next auth signer,
 * - sign the operation,
 * - burn the current key locally,
 * - persist before broadcast,
 * - broadcast,
 * - wait for inclusion,
 * - sync from on-chain storage.
 */
export type ExecuteParams = {
  target: Address;
  data: Hex;
  value?: bigint;

  /**
   * Absolute Unix deadline in seconds.
   *
   * If omitted, deadlineSeconds is used.
   */
  deadline?: bigint;

  /**
   * Relative deadline in seconds from now.
   *
   * Defaults inside OneTimeSignerWallet.
   */
  deadlineSeconds?: number;

  /**
   * Maximum number of derived auth keys to scan when searching for the next
   * unused signer.
   */
  maxLookahead?: number;
};

/**
 * Result returned after a normal execute flow.
 *
 * The receipt is intentionally not treated as the source of truth. The final
 * state comes from syncResult/state after re-reading on-chain storage.
 */
export type ExecuteResult = {
  operation: Operation;
  signedOperation: SignedOperation;
  operationDigest: Hex;
  txHash: Hex;
  receipt: unknown;
  syncResult: SyncResult;
  state: LocalWalletState;
};

/**
 * Parameters for recovery.
 *
 * Recovery can only be executed when local/on-chain state reconciles to PAUSED.
 */
export type RecoverParams = {
  /**
   * Absolute Unix deadline in seconds.
   */
  deadline?: bigint;

  /**
   * Relative deadline in seconds from now.
   */
  deadlineSeconds?: number;

  /**
   * Maximum number of derived auth keys to scan when selecting the new
   * authorized signer.
   */
  authLookahead?: number;

  /**
   * Maximum number of derived recovery keys to scan when selecting the new
   * recovery signer.
   */
  recoveryLookahead?: number;
};

/**
 * Result returned after a recovery flow.
 *
 * As with execute(), the final state is the post-transaction sync result.
 */
export type RecoverResult = {
  recoveryOperation: RecoveryOperation;
  signedRecoveryOperation: SignedRecoveryOperation;
  recoveryDigest: Hex;
  txHash: Hex;
  receipt: unknown;
  syncResult: SyncResult;
  state: LocalWalletState;
};

/**
 * Debug/introspection snapshot.
 *
 * Useful for UI/debugging without exposing low-level signing helpers.
 */
export type WalletSnapshot = {
  state: LocalWalletState;
  derivationContext: DerivationContext;
};