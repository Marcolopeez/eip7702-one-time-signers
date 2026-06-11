import { describe, expect, it } from "vitest";
import type { DerivationContext } from "../src/crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
  deriveSigner,
} from "../src/crypto/derivation.js";

const TEST_MNEMONIC =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

const BASE_CONTEXT: DerivationContext = {
  mnemonic: TEST_MNEMONIC,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};

describe("ephemeral signer derivation", () => {
  it("derives deterministic auth signers", () => {
    const first = deriveAuthSigner(BASE_CONTEXT, 0);
    const second = deriveAuthSigner(BASE_CONTEXT, 0);

    expect(first.privateKey).toBe(second.privateKey);
    expect(first.address).toBe(second.address);
    expect(first.path).toBe("m/7702'/60'/0'/0'/0'");
  });

  it("derives different auth indices", () => {
    const auth0 = deriveAuthSigner(BASE_CONTEXT, 0);
    const auth1 = deriveAuthSigner(BASE_CONTEXT, 1);

    expect(auth0.privateKey).not.toBe(auth1.privateKey);
    expect(auth0.address).not.toBe(auth1.address);
    expect(auth1.path).toBe("m/7702'/60'/0'/0'/1'");
  });

  it("separates auth and recovery streams", () => {
    const auth0 = deriveAuthSigner(BASE_CONTEXT, 0);
    const recovery0 = deriveRecoverySigner(BASE_CONTEXT, 0);

    expect(auth0.privateKey).not.toBe(recovery0.privateKey);
    expect(auth0.address).not.toBe(recovery0.address);
    expect(recovery0.path).toBe("m/7702'/60'/0'/1'/0'");
  });

  it("separates recovery indices", () => {
    const recovery0 = deriveRecoverySigner(BASE_CONTEXT, 0);
    const recovery1 = deriveRecoverySigner(BASE_CONTEXT, 1);

    expect(recovery0.privateKey).not.toBe(recovery1.privateKey);
    expect(recovery0.address).not.toBe(recovery1.address);
  });

  it("changes auth stream when walletId changes", () => {
    const authOriginal = deriveAuthSigner(BASE_CONTEXT, 0);

    const otherContext: DerivationContext = {
      ...BASE_CONTEXT,
      walletId: "0x2222222222222222222222222222222222222222222222222222222222222222",
    };

    const authOtherWallet = deriveAuthSigner(otherContext, 0);

    expect(authOriginal.privateKey).not.toBe(authOtherWallet.privateKey);
    expect(authOriginal.address).not.toBe(authOtherWallet.address);
  });

  it("does not change recovery stream when walletId changes", () => {
    const recoveryOriginal = deriveRecoverySigner(BASE_CONTEXT, 0);

    const otherContext: DerivationContext = {
      ...BASE_CONTEXT,
      walletId: "0x2222222222222222222222222222222222222222222222222222222222222222",
    };

    const recoveryOtherWallet = deriveRecoverySigner(otherContext, 0);

    expect(recoveryOriginal.privateKey).toBe(recoveryOtherWallet.privateKey);
    expect(recoveryOriginal.address).toBe(recoveryOtherWallet.address);
  });

  it("separates delegated accounts", () => {
    const authOriginal = deriveAuthSigner(BASE_CONTEXT, 0);

    const otherAccountContext: DerivationContext = {
      ...BASE_CONTEXT,
      delegatedAccount: "0x0000000000000000000000000000000000009999",
    };

    const authOtherAccount = deriveAuthSigner(otherAccountContext, 0);

    expect(authOriginal.privateKey).not.toBe(authOtherAccount.privateKey);
    expect(authOriginal.address).not.toBe(authOtherAccount.address);
  });

  it("separates chains", () => {
    const authOriginal = deriveAuthSigner(BASE_CONTEXT, 0);

    const otherChainContext: DerivationContext = {
      ...BASE_CONTEXT,
      chainId: 1,
    };

    const authOtherChain = deriveAuthSigner(otherChainContext, 0);

    expect(authOriginal.privateKey).not.toBe(authOtherChain.privateKey);
    expect(authOriginal.address).not.toBe(authOtherChain.address);
  });

  it("rejects negative indices", () => {
    expect(() => deriveSigner(BASE_CONTEXT, "auth", -1)).toThrow();
    expect(() => deriveSigner(BASE_CONTEXT, "recovery", -1)).toThrow();
  });

  it("rejects unsafe high indices", () => {
    expect(() => deriveSigner(BASE_CONTEXT, "auth", 2 ** 31)).toThrow();
    expect(() => deriveSigner(BASE_CONTEXT, "recovery", 2 ** 31)).toThrow();
  });
});