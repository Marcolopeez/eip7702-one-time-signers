/**
 * Small signing demo for local development.
 *
 * It derives test signers, signs both operation types, and recovers the signer
 * addresses from the resulting EIP-712 signatures.
 */
import type { DerivationContext } from "../../../../crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../../../../crypto/derivation.js";
import type {
  Eip712AccountContext,
  Operation,
  RecoveryOperation,
} from "../../../../protocol/one-time-signer-account/types.js";
import {
  hashOperationTypedData,
  hashRecoveryOperationTypedData,
  recoverOperationSigner,
  recoverRecoveryOperationSigner,
  signOperation,
  signRecoveryOperation,
} from "../../../../protocol/one-time-signer-account/eip712.js";

const mnemonic =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

const derivationContext: DerivationContext = {
  mnemonic,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};

const eip712Context: Eip712AccountContext = {
  chainId: 31337,
  delegatedAccount: derivationContext.delegatedAccount,
};

const auth0 = deriveAuthSigner(derivationContext, 0);
const auth1 = deriveAuthSigner(derivationContext, 1);

const recovery0 = deriveRecoverySigner(derivationContext, 0);
const recovery1 = deriveRecoverySigner(derivationContext, 1);

// A normal operation consumes auth[0] and proposes auth[1] as the next signer.
const operation: Operation = {
  target: "0x0000000000000000000000000000000000003000",
  value: 0n,
  data: "0x12345678",
  nextAuthorizedSigner: auth1.address,
  deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
};

const signedOperation = await signOperation({
  context: eip712Context,
  operation,
  privateKey: auth0.privateKey,
});

const recoveredOperationSigner = await recoverOperationSigner({
  context: eip712Context,
  operation,
  signature: signedOperation.signature,
});

console.log("Signed Operation");
console.log("----------------");
console.log("auth[0]:   ", auth0.address);
console.log("auth[1]:   ", auth1.address);
console.log("digest:    ", hashOperationTypedData(eip712Context, operation));
console.log("signature: ", signedOperation.signature);
console.log("recovered: ", recoveredOperationSigner);

// Recovery consumes recovery[0] and installs both auth[1] and recovery[1].
const recoveryOperation: RecoveryOperation = {
  nextAuthorizedSigner: auth1.address,
  nextRecoverySigner: recovery1.address,
  deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
};

const signedRecovery = await signRecoveryOperation({
  context: eip712Context,
  recoveryOperation,
  privateKey: recovery0.privateKey,
});

const recoveredRecoverySigner = await recoverRecoveryOperationSigner({
  context: eip712Context,
  recoveryOperation,
  signature: signedRecovery.signature,
});

console.log("");
console.log("Signed RecoveryOperation");
console.log("------------------------");
console.log("recovery[0]: ", recovery0.address);
console.log("recovery[1]: ", recovery1.address);
console.log("digest:      ", hashRecoveryOperationTypedData(eip712Context, recoveryOperation));
console.log("signature:   ", signedRecovery.signature);
console.log("recovered:   ", recoveredRecoverySigner);
