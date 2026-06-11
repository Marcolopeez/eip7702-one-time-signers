import { describe, expect, it } from "vitest";
import { getAddress, keccak256 } from "viem";
import type { DerivationContext } from "../src/crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../src/crypto/derivation.js";
import type {
  Eip712AccountContext,
  Operation,
  RecoveryOperation,
} from "../src/account/types.js";
import {
  buildEip712Domain,
  buildOperationTypedMessage,
  hashOperationTypedData,
  hashRecoveryOperationTypedData,
  recoverOperationSigner,
  recoverRecoveryOperationSigner,
  signOperation,
  signRecoveryOperation,
} from "../src/account/eip712.js";

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

const DERIVATION_CONTEXT: DerivationContext = {
  mnemonic: TEST_MNEMONIC,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};

const EIP712_CONTEXT: Eip712AccountContext = {
  chainId: 31337,
  delegatedAccount: DERIVATION_CONTEXT.delegatedAccount,
};

describe("EIP-712 operation signing", () => {
  it("builds the expected EIP-712 domain", () => {
    const domain = buildEip712Domain(EIP712_CONTEXT);

    expect(domain).toEqual({
      name: "EphemeralKeyAccount",
      version: "1",
      chainId: 31337,
      verifyingContract: getAddress(DERIVATION_CONTEXT.delegatedAccount),
    });
  });

  it("converts Operation.data into dataHash before signing", () => {
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9999999999n,
    };

    const typedMessage = buildOperationTypedMessage(operation);

    expect(typedMessage).toEqual({
      target: getAddress(operation.target),
      value: 0n,
      dataHash: keccak256("0x12345678"),
      nextAuthorizedSigner: getAddress(auth1.address),
      deadline: 9999999999n,
    });
  });

  it("signs an Operation with auth[0] and recovers auth[0]", async () => {
    const auth0 = deriveAuthSigner(DERIVATION_CONTEXT, 0);
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9999999999n,
    };

    const signed = await signOperation({
      context: EIP712_CONTEXT,
      operation,
      privateKey: auth0.privateKey,
    });

    const recovered = await recoverOperationSigner({
      context: EIP712_CONTEXT,
      operation,
      signature: signed.signature,
    });

    expect(signed.signer).toBe(auth0.address);
    expect(recovered).toBe(auth0.address);
  });

  it("changing nextAuthorizedSigner changes the Operation digest", () => {
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);
    const auth2 = deriveAuthSigner(DERIVATION_CONTEXT, 2);

    const baseOperation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9999999999n,
    };

    const changedOperation: Operation = {
      ...baseOperation,
      nextAuthorizedSigner: auth2.address,
    };

    const baseDigest = hashOperationTypedData(EIP712_CONTEXT, baseOperation);
    const changedDigest = hashOperationTypedData(EIP712_CONTEXT, changedOperation);

    expect(baseDigest).not.toBe(changedDigest);
  });

  it("changing data changes the Operation digest", () => {
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const baseOperation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9999999999n,
    };

    const changedOperation: Operation = {
      ...baseOperation,
      data: "0xdeadbeef",
    };

    const baseDigest = hashOperationTypedData(EIP712_CONTEXT, baseOperation);
    const changedDigest = hashOperationTypedData(EIP712_CONTEXT, changedOperation);

    expect(baseDigest).not.toBe(changedDigest);
  });

  it("changing chainId changes the Operation digest", () => {
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9999999999n,
    };

    const digest31337 = hashOperationTypedData(EIP712_CONTEXT, operation);

    const digestMainnet = hashOperationTypedData(
      {
        ...EIP712_CONTEXT,
        chainId: 1,
      },
      operation,
    );

    expect(digest31337).not.toBe(digestMainnet);
  });

  it("changing delegatedAccount changes the Operation digest", () => {
    const auth1 = deriveAuthSigner(DERIVATION_CONTEXT, 1);

    const operation: Operation = {
      target: "0x0000000000000000000000000000000000003000",
      value: 0n,
      data: "0x12345678",
      nextAuthorizedSigner: auth1.address,
      deadline: 9999999999n,
    };

    const baseDigest = hashOperationTypedData(EIP712_CONTEXT, operation);

    const otherAccountDigest = hashOperationTypedData(
      {
        ...EIP712_CONTEXT,
        delegatedAccount: "0x0000000000000000000000000000000000009999",
      },
      operation,
    );

    expect(baseDigest).not.toBe(otherAccountDigest);
  });
});

describe("EIP-712 recovery operation signing", () => {
  it("signs a RecoveryOperation with recovery[0] and recovers recovery[0]", async () => {
    const recovery0 = deriveRecoverySigner(DERIVATION_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);

    const recoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9999999999n,
    };

    const signed = await signRecoveryOperation({
      context: EIP712_CONTEXT,
      recoveryOperation,
      privateKey: recovery0.privateKey,
    });

    const recovered = await recoverRecoveryOperationSigner({
      context: EIP712_CONTEXT,
      recoveryOperation,
      signature: signed.signature,
    });

    expect(signed.signer).toBe(recovery0.address);
    expect(recovered).toBe(recovery0.address);
  });

  it("changing nextRecoverySigner changes the RecoveryOperation digest", () => {
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);
    const recovery2 = deriveRecoverySigner(DERIVATION_CONTEXT, 2);

    const baseRecoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9999999999n,
    };

    const changedRecoveryOperation: RecoveryOperation = {
      ...baseRecoveryOperation,
      nextRecoverySigner: recovery2.address,
    };

    const baseDigest = hashRecoveryOperationTypedData(
      EIP712_CONTEXT,
      baseRecoveryOperation,
    );

    const changedDigest = hashRecoveryOperationTypedData(
      EIP712_CONTEXT,
      changedRecoveryOperation,
    );

    expect(baseDigest).not.toBe(changedDigest);
  });

  it("changing nextAuthorizedSigner changes the RecoveryOperation digest", () => {
    const auth10 = deriveAuthSigner(DERIVATION_CONTEXT, 10);
    const auth11 = deriveAuthSigner(DERIVATION_CONTEXT, 11);
    const recovery1 = deriveRecoverySigner(DERIVATION_CONTEXT, 1);

    const baseRecoveryOperation: RecoveryOperation = {
      nextAuthorizedSigner: auth10.address,
      nextRecoverySigner: recovery1.address,
      deadline: 9999999999n,
    };

    const changedRecoveryOperation: RecoveryOperation = {
      ...baseRecoveryOperation,
      nextAuthorizedSigner: auth11.address,
    };

    const baseDigest = hashRecoveryOperationTypedData(
      EIP712_CONTEXT,
      baseRecoveryOperation,
    );

    const changedDigest = hashRecoveryOperationTypedData(
      EIP712_CONTEXT,
      changedRecoveryOperation,
    );

    expect(baseDigest).not.toBe(changedDigest);
  });
});