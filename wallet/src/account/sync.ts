/**
 * Pure reconciliation between local wallet state and on-chain account storage.
 *
 * This module intentionally performs no RPC calls. The client builds an
 * OnchainAccountSnapshot, and this file decides how local state should move.
 */
import { getAddress, type Address } from "viem";
import {
  applyOperationAdvanced,
  applyOperationPaused,
  applyRecoveryFailedButConsumed,
  applyRecoverySucceeded,
  markPaused,
  type LocalWalletState,
} from "./state.js";

/** Snapshot of the delegated account storage needed for one sync step. */
export type OnchainAccountSnapshot = {
  isInitialized: boolean;
  isPaused: boolean;
  currentAuthorizedSigner: Address;

  /**
   * Only needed while PENDING_RECOVERY.
   *
   * Before the recovery tx is mined:
   *   current recovery signer should still be active.
   *
   * After a failed-but-consumed recovery:
   *   current recovery signer is no longer active.
   */
  currentRecoverySignerActive?: boolean;

  /**
   * Only needed while PENDING_RECOVERY.
   *
   * If recovery succeeds fully:
   *   nextRecoverySigner should be active.
   *
   * If auth rotates but recovery registration fails:
   *   nextRecoverySigner is not active.
   */
  nextRecoverySignerActive?: boolean;
};

/** Machine-readable explanation of the reconciliation outcome. */
export type SyncReason =
  | "UNCHANGED_READY"
  | "UNCHANGED_PENDING_OPERATION"
  | "UNCHANGED_PAUSED"
  | "UNCHANGED_PENDING_RECOVERY"
  | "READY_TO_PAUSED"
  | "PENDING_OPERATION_TO_READY"
  | "PENDING_OPERATION_TO_PAUSED"
  | "PENDING_RECOVERY_TO_READY"
  | "PENDING_RECOVERY_TO_PAUSED";

export type SyncResult = {
  state: LocalWalletState;
  changed: boolean;
  reason: SyncReason;
  snapshot: OnchainAccountSnapshot;
};

/**
 * Raised when local state and on-chain storage cannot be reconciled safely.
 *
 * These errors should stop signing rather than guessing a new local state.
 */
export class SyncInvariantError extends Error {
  readonly name = "SyncInvariantError";

  constructor(message: string) {
    super(message);
  }
}

function sameAddress(a: Address, b: Address): boolean {
  return getAddress(a) === getAddress(b);
}

function requireInitialized(snapshot: OnchainAccountSnapshot): void {
  if (!snapshot.isInitialized) {
    throw new SyncInvariantError("Delegated account is not initialized on-chain");
  }
}

/**
 * Applies the wallet state machine using contract storage as the source of truth.
 *
 * Receipt status is intentionally ignored here: a successful Ethereum receipt can
 * still correspond to a function-level `(success = false, result)` return.
 */
export function reconcileLocalState(
  state: LocalWalletState,
  snapshot: OnchainAccountSnapshot,
): SyncResult {
  requireInitialized(snapshot);

  const currentOnchainSigner = getAddress(snapshot.currentAuthorizedSigner);
  const currentLocalSigner = getAddress(state.currentAuthorizedSigner);

  switch (state.status) {
    case "READY": {
      // READY is stable only when the on-chain signer still matches local state.
      if (snapshot.isPaused) {
        return {
          state: markPaused(state),
          changed: true,
          reason: "READY_TO_PAUSED",
          snapshot,
        };
      }

      if (sameAddress(currentOnchainSigner, currentLocalSigner)) {
        return {
          state,
          changed: false,
          reason: "UNCHANGED_READY",
          snapshot,
        };
      }

      throw new SyncInvariantError(
        `READY desync: on-chain signer is ${currentOnchainSigner}, local signer is ${currentLocalSigner}`,
      );
    }

    case "PENDING_OPERATION": {
      // A pending operation can either still be waiting, rotate successfully, or pause.
      const pending = state.pendingOperation;

      if (!pending) {
        throw new SyncInvariantError("PENDING_OPERATION without pendingOperation");
      }

      if (snapshot.isPaused) {
        return {
          state: applyOperationPaused(state),
          changed: true,
          reason: "PENDING_OPERATION_TO_PAUSED",
          snapshot,
        };
      }

      if (sameAddress(currentOnchainSigner, pending.nextAuthorizedSigner)) {
        return {
          state: applyOperationAdvanced(state),
          changed: true,
          reason: "PENDING_OPERATION_TO_READY",
          snapshot,
        };
      }

      if (sameAddress(currentOnchainSigner, pending.consumedAuthSigner)) {
        return {
          state,
          changed: false,
          reason: "UNCHANGED_PENDING_OPERATION",
          snapshot,
        };
      }

      throw new SyncInvariantError(
        `PENDING_OPERATION desync: on-chain signer is ${currentOnchainSigner}, expected either consumed signer ${pending.consumedAuthSigner} or next signer ${pending.nextAuthorizedSigner}`,
      );
    }

    case "PAUSED": {
      // In this prototype, PAUSED can only be left through an explicit recovery flow.
      if (snapshot.isPaused) {
        return {
          state,
          changed: false,
          reason: "UNCHANGED_PAUSED",
          snapshot,
        };
      }

      throw new SyncInvariantError(
        `PAUSED desync: local state is paused but on-chain account is unpaused with signer ${currentOnchainSigner}`,
      );
    }

    case "PENDING_RECOVERY": {
      const pending = state.pendingRecovery;

      if (!pending) {
        throw new SyncInvariantError("PENDING_RECOVERY without pendingRecovery");
      }

      /**
       * Case 1:
       * The tx has not landed yet.
       *
       * On-chain:
       * - still paused
       * - current authorized signer has not changed
       * - current recovery signer is still active
       */
      if (
        snapshot.isPaused &&
        sameAddress(currentOnchainSigner, currentLocalSigner) &&
        snapshot.currentRecoverySignerActive === true
      ) {
        return {
          state,
          changed: false,
          reason: "UNCHANGED_PENDING_RECOVERY",
          snapshot,
        };
      }

      /**
       * Case 2:
       * Recovery signature was consumed but recovery failed.
       *
       * On-chain:
       * - still paused
       * - current recovery signer is no longer active
       */
      if (
        snapshot.isPaused &&
        sameAddress(currentOnchainSigner, currentLocalSigner) &&
        snapshot.currentRecoverySignerActive === false
      ) {
        return {
          state: applyRecoveryFailedButConsumed(state),
          changed: true,
          reason: "PENDING_RECOVERY_TO_PAUSED",
          snapshot,
        };
      }

      /**
       * Case 3:
       * Full recovery succeeded.
       *
       * On-chain:
       * - unpaused
       * - current authorized signer advanced
       * - next recovery signer was registered
       */
      if (
        !snapshot.isPaused &&
        sameAddress(currentOnchainSigner, pending.nextAuthorizedSigner) &&
        snapshot.nextRecoverySignerActive === true
      ) {
        return {
          state: applyRecoverySucceeded(state),
          changed: true,
          reason: "PENDING_RECOVERY_TO_READY",
          snapshot,
        };
      }

      /**
       * Case 4:
       * Partial recovery.
       *
       * On-chain:
       * - unpaused
       * - authorized signer advanced
       * - next recovery signer was NOT registered
       *
       * This matches the subtle contract case where nextAuthorizedSigner was valid
       * but nextRecoverySigner failed validation.
       */
      if (
        !snapshot.isPaused &&
        sameAddress(currentOnchainSigner, pending.nextAuthorizedSigner) &&
        snapshot.nextRecoverySignerActive === false
      ) {
        throw new SyncInvariantError(
          "Critical partial recovery: authorized signer advanced but next recovery signer is not active",
        );
      }

      throw new SyncInvariantError(
        `PENDING_RECOVERY desync: on-chain signer is ${currentOnchainSigner}, paused=${snapshot.isPaused}`,
      );
    }
  }
}