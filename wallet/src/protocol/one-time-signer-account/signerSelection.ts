/**
 * On-chain-aware signer selection helpers.
 *
 * These functions scan deterministic signer streams and skip keys that are
 * burned locally or already consumed/reserved by the delegated account.
 */
import type { Address } from "viem";
import type {
  DerivationContext,
  DerivedSigner,
} from "../../crypto/derivation.js";
import { deriveAuthSigner, deriveRecoverySigner } from "../../crypto/derivation.js";

/** Minimal read interface required to reject already-used auth signers. */
export type SignerReservationReader = {
  readIsConsumedOrReservedSigner(signer: Address): Promise<boolean>;
};

/** Minimal read interface required to check whether a recovery signer is active. */
export type RecoverySignerReader = {
  readIsActiveRecoverySigner(signer: Address): Promise<boolean>;
};

export type KeyStatusReader = SignerReservationReader & RecoverySignerReader;

function isLocallyBurned(
  localBurnedIndices: ReadonlyArray<number> | undefined,
  index: number,
): boolean {
  return localBurnedIndices?.includes(index) ?? false;
}

/**
 * Finds the next auth signer that is safe to install as nextAuthorizedSigner.
 *
 * The search starts at startIndex and is bounded to avoid accidentally scanning
 * an unbounded key space when local state is wrong.
 */
export async function findNextUnusedAuthSigner(params: {
  context: DerivationContext;
  startIndex: number;
  reader: SignerReservationReader;
  maxLookahead?: number;
  localBurnedIndices?: ReadonlyArray<number>;
}): Promise<DerivedSigner> {
  const maxLookahead = params.maxLookahead ?? 50;

  for (let offset = 0; offset < maxLookahead; offset++) {
    const index = params.startIndex + offset;

    if (isLocallyBurned(params.localBurnedIndices, index)) {
      continue;
    }

    const signer = deriveAuthSigner(params.context, index);

    const consumedOrReserved =
      await params.reader.readIsConsumedOrReservedSigner(signer.address);

    if (!consumedOrReserved) {
      return signer;
    }
  }

  throw new Error(
    `Could not find unused auth signer in lookahead window of ${maxLookahead}`,
  );
}

/**
 * Finds a recovery signer suitable for registration during recovery rotation.
 *
 * A valid next recovery signer must be inactive, not consumed/reserved on-chain,
 * and not already burned locally.
 */
export async function findNextAvailableRecoverySigner(params: {
  context: DerivationContext;
  startIndex: number;
  reader: KeyStatusReader;
  maxLookahead?: number;
  localBurnedIndices?: ReadonlyArray<number>;
}): Promise<DerivedSigner> {
  const maxLookahead = params.maxLookahead ?? 50;

  for (let offset = 0; offset < maxLookahead; offset++) {
    const index = params.startIndex + offset;

    if (isLocallyBurned(params.localBurnedIndices, index)) {
      continue;
    }

    const signer = deriveRecoverySigner(params.context, index);

    const [active, consumedOrReserved] = await Promise.all([
      params.reader.readIsActiveRecoverySigner(signer.address),
      params.reader.readIsConsumedOrReservedSigner(signer.address),
    ]);

    if (!active && !consumedOrReserved) {
      return signer;
    }
  }

  throw new Error(
    `Could not find available recovery signer in lookahead window of ${maxLookahead}`,
  );
}

/**
 * Kept for compatibility with older scripts.
 *
 * Prefer findNextAvailableRecoverySigner() for recovery rotation because
 * a recovery signer should be both inactive and not consumed/reserved.
 */
export async function findNextInactiveRecoverySigner(params: {
  context: DerivationContext;
  startIndex: number;
  reader: RecoverySignerReader;
  maxLookahead?: number;
  localBurnedIndices?: ReadonlyArray<number>;
}): Promise<DerivedSigner> {
  const maxLookahead = params.maxLookahead ?? 50;

  for (let offset = 0; offset < maxLookahead; offset++) {
    const index = params.startIndex + offset;

    if (isLocallyBurned(params.localBurnedIndices, index)) {
      continue;
    }

    const signer = deriveRecoverySigner(params.context, index);

    const active = await params.reader.readIsActiveRecoverySigner(signer.address);

    if (!active) {
      return signer;
    }
  }

  throw new Error(
    `Could not find inactive recovery signer in lookahead window of ${maxLookahead}`,
  );
}