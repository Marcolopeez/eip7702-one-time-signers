/**
 * Shared account-layer types.
 *
 * These types intentionally distinguish between the calldata sent to the
 * contract and the EIP-712 message that is signed off-chain.
 */
import type { Address, Hex } from "viem";

/**
 * Operation calldata accepted by executeSignedAndRotate.
 */
export type Operation = {
  target: Address;
  value: bigint;
  data: Hex;
  nextAuthorizedSigner: Address;
  deadline: bigint;
};

/**
 * EIP-712 representation of Operation.
 *
 * The contract signs keccak256(data), not raw bytes data. Keeping this as a
 * separate type makes that distinction explicit in the wallet code.
 */
export type OperationTypedMessage = {
  target: Address;
  value: bigint;
  dataHash: Hex;
  nextAuthorizedSigner: Address;
  deadline: bigint;
};

/**
 * Recovery calldata accepted by signedRecovery.
 *
 * A successful recovery installs both a fresh authorized signer and a fresh
 * recovery signer, preserving the one-time-key model for both streams.
 */
export type RecoveryOperation = {
  nextAuthorizedSigner: Address;
  nextRecoverySigner: Address;
  deadline: bigint;
};

/**
 * Minimal context needed to build the EIP-712 domain.
 */
export type Eip712AccountContext = {
  chainId: number;
  delegatedAccount: Address;
};

/**
 * Result of signing an Operation.
 *
 * The signer is returned so the state machine can assert that the current
 * authorized signer was the key that actually produced the signature.
 */
export type SignedOperation = {
  operation: Operation;
  typedMessage: OperationTypedMessage;
  signature: Hex;
  signer: Address;
};

/**
 * Result of signing a RecoveryOperation.
 */
export type SignedRecoveryOperation = {
  recoveryOperation: RecoveryOperation;
  signature: Hex;
  signer: Address;
};
