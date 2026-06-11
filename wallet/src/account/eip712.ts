/**
 * EIP-712 helpers for the delegated account wallet.
 *
 * This module mirrors the typed-data format expected by EphemeralKeyAccount.sol.
 * It is intentionally stateless: key consumption is handled by the local state
 * machine, not by these low-level signing helpers.
 */
import {
  getAddress,
  hashTypedData,
  keccak256,
  recoverTypedDataAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type {
  Eip712AccountContext,
  Operation,
  OperationTypedMessage,
  RecoveryOperation,
  SignedOperation,
  SignedRecoveryOperation,
} from "./types.js";

export const EIP712_NAME = "EphemeralKeyAccount";
export const EIP712_VERSION = "1";

/**
 * Matches the Solidity Operation typehash.
 *
 * The contract signs a bytes32 dataHash instead of raw bytes data, so callers
 * must convert Operation.data before building the typed message.
 */
export const operationTypes = {
  Operation: [
    { name: "target", type: "address" },
    { name: "value", type: "uint256" },
    { name: "dataHash", type: "bytes32" },
    { name: "nextAuthorizedSigner", type: "address" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

/**
 * Recovery signatures rotate both the normal authorization stream and the
 * recovery stream itself.
 */
export const recoveryOperationTypes = {
  RecoveryOperation: [
    { name: "nextAuthorizedSigner", type: "address" },
    { name: "nextRecoverySigner", type: "address" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

/**
 * Builds the EIP-712 domain used by the delegated EOA.
 *
 * Under EIP-7702, the verifying contract is the delegated account address
 * itself, not the implementation contract containing the code.
 */
export function buildEip712Domain(context: Eip712AccountContext) {
  if (!Number.isSafeInteger(context.chainId) || context.chainId <= 0) {
    throw new Error("chainId must be a positive safe integer");
  }

  return {
    name: EIP712_NAME,
    version: EIP712_VERSION,
    chainId: context.chainId,
    verifyingContract: getAddress(context.delegatedAccount),
  } as const;
}

/**
 * Converts the runtime Operation into the exact typed-data message signed by
 * the current authorized signer.
 */
export function buildOperationTypedMessage(operation: Operation): OperationTypedMessage {
  return {
    target: getAddress(operation.target),
    value: operation.value,
    dataHash: keccak256(operation.data),
    nextAuthorizedSigner: getAddress(operation.nextAuthorizedSigner),
    deadline: operation.deadline,
  };
}

/**
 * Canonicalizes addresses before signing or recovering a recovery operation.
 */
export function normalizeRecoveryOperation(
  recoveryOperation: RecoveryOperation,
): RecoveryOperation {
  return {
    nextAuthorizedSigner: getAddress(recoveryOperation.nextAuthorizedSigner),
    nextRecoverySigner: getAddress(recoveryOperation.nextRecoverySigner),
    deadline: recoveryOperation.deadline,
  };
}

/**
 * Returns the digest that should match the contract-side Operation EIP-712 hash.
 */
export function hashOperationTypedData(
  context: Eip712AccountContext,
  operation: Operation,
): Hex {
  return hashTypedData({
    domain: buildEip712Domain(context),
    types: operationTypes,
    primaryType: "Operation",
    message: buildOperationTypedMessage(operation),
  });
}

/**
 * Returns the digest that should match the contract-side RecoveryOperation hash.
 */
export function hashRecoveryOperationTypedData(
  context: Eip712AccountContext,
  recoveryOperation: RecoveryOperation,
): Hex {
  return hashTypedData({
    domain: buildEip712Domain(context),
    types: recoveryOperationTypes,
    primaryType: "RecoveryOperation",
    message: normalizeRecoveryOperation(recoveryOperation),
  });
}

/**
 * Signs an Operation with a raw private key.
 *
 * This is a low-level primitive. Production flows should call it through the
 * wallet state machine so the consumed auth key is burned immediately after
 * the signature is produced.
 */
export async function signOperation(params: {
  context: Eip712AccountContext;
  operation: Operation;
  privateKey: Hex;
}): Promise<SignedOperation> {
  const account = privateKeyToAccount(params.privateKey);
  const typedMessage = buildOperationTypedMessage(params.operation);

  const signature = await account.signTypedData({
    domain: buildEip712Domain(params.context),
    types: operationTypes,
    primaryType: "Operation",
    message: typedMessage,
  });

  return {
    operation: params.operation,
    typedMessage,
    signature,
    signer: account.address,
  };
}

/**
 * Signs a RecoveryOperation with an active recovery key.
 *
 * As with normal operation signing, the caller must treat the recovery key as
 * consumed as soon as this function returns a signature.
 */
export async function signRecoveryOperation(params: {
  context: Eip712AccountContext;
  recoveryOperation: RecoveryOperation;
  privateKey: Hex;
}): Promise<SignedRecoveryOperation> {
  const account = privateKeyToAccount(params.privateKey);
  const normalizedRecoveryOperation = normalizeRecoveryOperation(params.recoveryOperation);

  const signature = await account.signTypedData({
    domain: buildEip712Domain(params.context),
    types: recoveryOperationTypes,
    primaryType: "RecoveryOperation",
    message: normalizedRecoveryOperation,
  });

  return {
    recoveryOperation: normalizedRecoveryOperation,
    signature,
    signer: account.address,
  };
}

/**
 * Recovers the signer of an Operation signature.
 *
 * Used by tests and local consistency checks before submitting to the chain.
 */
export async function recoverOperationSigner(params: {
  context: Eip712AccountContext;
  operation: Operation;
  signature: Hex;
}): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: buildEip712Domain(params.context),
    types: operationTypes,
    primaryType: "Operation",
    message: buildOperationTypedMessage(params.operation),
    signature: params.signature,
  });

  return getAddress(recovered);
}

/**
 * Recovers the signer of a RecoveryOperation signature.
 */
export async function recoverRecoveryOperationSigner(params: {
  context: Eip712AccountContext;
  recoveryOperation: RecoveryOperation;
  signature: Hex;
}): Promise<Address> {
  const recovered = await recoverTypedDataAddress({
    domain: buildEip712Domain(params.context),
    types: recoveryOperationTypes,
    primaryType: "RecoveryOperation",
    message: normalizeRecoveryOperation(params.recoveryOperation),
    signature: params.signature,
  });

  return getAddress(recovered);
}
