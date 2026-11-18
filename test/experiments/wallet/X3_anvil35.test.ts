/**
 * X3 / AFIRMACIONES #35 en Anvil, con el cliente viem real (`OneTimeSignerAccountClient`) y el SDK real.
 * ¿Con un target como el de H1 falla la estimación de gas de viem después de que la wallet guarde PENDING_OPERATION?
 *
 * Solo se ejecuta con el driver experimentos/X3-recuperacion/scripts/anvil-35.sh, que arranca Anvil, despliega OTS y
 * ReturnBombTarget y exporta X3_ANVIL_RPC, X3_IMPL, X3_BOMB, X3_H_PK y X3_RELAYER_PK. Sin esas variables se omite.
 */
import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";
import { encodeFunctionData, getAddress, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { OneTimeSignerAccountClient } from "../../../wallet/src/adapters/viem/OneTimeSignerAccountClient.js";
import { OneTimeSignerWallet } from "../../../wallet/src/sdk/OneTimeSignerWallet.js";
import type { WalletStateStore } from "../../../wallet/src/sdk/ports.js";
import { deriveAuthSigner, deriveRecoverySigner, type DerivationContext } from "../../../wallet/src/crypto/derivation.js";
import { signRecoveryOperation } from "../../../wallet/src/protocol/one-time-signer-account/eip712.js";
import { createInitialWalletState, type LocalWalletState } from "../../../wallet/src/protocol/one-time-signer-account/state.js";

const env = process.env;
const RPC = env.X3_ANVIL_RPC;
const MNEMONIC = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
const WALLET_ID = "0x1111111111111111111111111111111111111111111111111111111111111111" as Hex;

class MemoryStore implements WalletStateStore {
  constructor(public state: LocalWalletState | null) {}
  async load() {
    return this.state;
  }
  async save(s: LocalWalletState) {
    this.state = s;
  }
}

async function rpc(method: string, params: unknown[] = []): Promise<any> {
  const r = await fetch(RPC!, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  return (await r.json()).result;
}

describe.skipIf(!RPC)("#35 en Anvil: target de H1 con la wallet real", () => {
  it("la estimación falla tras guardar PENDING_OPERATION; no se difunde; la salida solo es por el contrato", async () => {
    const A = privateKeyToAccount(env.X3_H_PK as Hex).address;
    const IMPL = getAddress(env.X3_IMPL!);
    const BOMB = getAddress(env.X3_BOMB!);
    const ctx: DerivationContext = {
      mnemonic: MNEMONIC, passphrase: "", walletId: WALLET_ID, chainId: 31337,
      delegatedAccount: A, implementationAddress: IMPL, accountIndex: 0,
    };
    const auth0 = deriveAuthSigner(ctx, 0);
    const rec0 = deriveRecoverySigner(ctx, 0);

    // Migración del TFM en una tipo 4 real (cast), con los firmantes derivados por la wallet.
    execFileSync("cast", [
      "send", A, "initialize(address,address[])", auth0.address, `[${rec0.address}]`,
      "--auth", IMPL, "--private-key", env.X3_H_PK!, "--rpc-url", RPC!,
    ]);
    const code: Hex = await rpc("eth_getCode", [A, "latest"]);
    expect(code.toLowerCase()).toBe(`0xef0100${IMPL.slice(2).toLowerCase()}`);

    const client = new OneTimeSignerAccountClient({
      rpcUrl: RPC!, chainId: 31337, delegatedAccount: A, relayerPrivateKey: env.X3_RELAYER_PK as Hex,
    });
    const store = new MemoryStore(createInitialWalletState({
      chainId: 31337, delegatedAccount: A, implementationAddress: IMPL, walletId: WALLET_ID, accountIndex: 0,
      initialAuthIndex: 0, initialAuthorizedSigner: auth0.address, initialRecoveryIndex: 0,
      initialRecoverySigner: rec0.address, nowUnix: Math.floor(Date.now() / 1000),
    }));
    const wallet = new OneTimeSignerWallet({ mnemonic: MNEMONIC, passphrase: "", store, client });
    expect((await wallet.sync()).state.status).toBe("READY");

    const blockBefore = BigInt(await rpc("eth_blockNumber"));
    const data = encodeFunctionData({
      abi: [{ type: "function", name: "setNumber", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }], stateMutability: "nonpayable" }],
      functionName: "setNumber", args: [42n],
    });
    let err: unknown;
    try {
      await wallet.execute({ target: BOMB, data, deadlineSeconds: 3600 });
    } catch (e) {
      err = e;
    }
    expect(err, "execute debe fallar").toBeDefined();
    console.log("#35 error de viem:", String((err as Error).message).split("\n").slice(0, 3).join(" | "));

    // Estado final: local PENDING_OPERATION; on-chain sin cambios; nada en el pool ni bloque nuevo.
    expect(store.state!.status).toBe("PENDING_OPERATION");
    expect(store.state!.pendingOperation?.txHash).toBeUndefined();
    expect(await client.readCurrentAuthorizedSigner()).toBe(auth0.address);
    expect(BigInt(await rpc("eth_blockNumber"))).toBe(blockBefore);
    const pool = await rpc("txpool_content");
    expect(Object.keys(pool.pending ?? {}).length + Object.keys(pool.queued ?? {}).length).toBe(0);

    // Operaciones posteriores por la wallet: ninguna ruta (estado D1 de H2).
    expect((await wallet.sync()).reason).toBe("UNCHANGED_PENDING_OPERATION");
    await expect(wallet.execute({ target: BOMB, data })).rejects.toThrow("PENDING_OPERATION");
    await expect(wallet.recover()).rejects.toThrow("expected PAUSED");

    // Salida por el contrato (fuera del SDK): signedRecovery con rec0, la cuenta activa.
    const next = deriveAuthSigner(ctx, 2);
    const nextRec = deriveRecoverySigner(ctx, 1);
    const recoveryOperation = {
      nextAuthorizedSigner: next.address, nextRecoverySigner: nextRec.address,
      deadline: BigInt(Math.floor(Date.now() / 1000) + 3600),
    };
    const signed = await signRecoveryOperation({
      context: { chainId: 31337, delegatedAccount: A }, recoveryOperation, privateKey: rec0.privateKey,
    });
    const tx = await client.signedRecovery({ recoveryOperation, signature: signed.signature });
    const receipt = await client.waitForReceipt(tx);
    expect(receipt.status).toBe("success");
    expect(await client.readCurrentAuthorizedSigner()).toBe(next.address);
    expect(await client.readIsActiveRecoverySigner(rec0.address)).toBe(false);
    // Y la wallet local sigue sin reconocer el estado (no hay ruta de reconciliación).
    await expect(wallet.sync()).rejects.toThrow();
  });
});
