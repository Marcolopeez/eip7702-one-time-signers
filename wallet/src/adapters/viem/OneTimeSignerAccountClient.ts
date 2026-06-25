/**
 * viem-backed client for the delegated account.
 *
 * The client separates read-only synchronization from relayed writes. Auth and
 * recovery keys never pay gas here; they only sign EIP-712 payloads off-chain.
 */
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  getAddress,
  http,
  type Address,
  type Hex,
  type PublicClient,
} from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import { OneTimeSignerAccountAbi } from "../../contracts/OneTimeSignerAccount.abi.js";
import {
  reconcileLocalState,
  type OnchainAccountSnapshot,
  type SyncResult,
} from "../../protocol/one-time-signer-account/sync.js";
import type { LocalWalletState } from "../../protocol/one-time-signer-account/state.js";
import type { Operation, RecoveryOperation } from "../../protocol/one-time-signer-account/types.js";

export type OneTimeSignerAccountClientConfig = {
  rpcUrl: string;
  chainId: number;
  delegatedAccount: Address;

  /**
   * Optional transaction relayer.
   *
   * The relayer pays gas for executeSignedAndRotate/signedRecovery.
   * It is NOT the auth signer.
   */
  relayerPrivateKey?: Hex;
};

/**
 * Thin RPC adapter around OneTimeSignerAccount.
 *
 * It deliberately delegates state interpretation to sync.ts so the critical
 * reconciliation rules stay pure and unit-testable.
 */
export class OneTimeSignerAccountClient {
  readonly publicClient: PublicClient;
  readonly walletClient?: ReturnType<typeof createWalletClient>;
  readonly relayerAccount?: PrivateKeyAccount;
  readonly delegatedAccount: Address;

  constructor(config: OneTimeSignerAccountClientConfig) {
    if (!Number.isSafeInteger(config.chainId) || config.chainId <= 0) {
      throw new Error("chainId must be a positive safe integer");
    }

    this.delegatedAccount = getAddress(config.delegatedAccount);

    // Local/dev chains are defined at runtime because Anvil uses configurable IDs.
    const chain = defineChain({
      id: config.chainId,
      name: `Local chain ${config.chainId}`,
      nativeCurrency: {
        name: "Ether",
        symbol: "ETH",
        decimals: 18,
      },
      rpcUrls: {
        default: {
          http: [config.rpcUrl],
        },
      },
    });

    this.publicClient = createPublicClient({
      chain,
      transport: http(config.rpcUrl),
    });

    // Writes are optional. A read-only client is enough for sync().
    if (config.relayerPrivateKey) {
      this.relayerAccount = privateKeyToAccount(config.relayerPrivateKey);

      this.walletClient = createWalletClient({
        account: this.relayerAccount,
        chain,
        transport: http(config.rpcUrl),
      });
    }
  }

  private requireWalletClient(): ReturnType<typeof createWalletClient> {
    if (!this.walletClient || !this.relayerAccount) {
      throw new Error("This action requires relayerPrivateKey");
    }

    return this.walletClient;
  }

  async readIsInitialized(): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "isInitialized",
    });
  }

  async readIsPaused(): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "isPaused",
    });
  }

  async readCurrentAuthorizedSigner(): Promise<Address> {
    const signer = await this.publicClient.readContract({
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "currentAuthorizedSigner",
    });

    return getAddress(signer);
  }

  async readIsConsumedOrReservedSigner(signer: Address): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "isConsumedOrReservedSigner",
      args: [getAddress(signer)],
    });
  }

  async readIsActiveRecoverySigner(signer: Address): Promise<boolean> {
    return this.publicClient.readContract({
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "isActiveRecoverySigner",
      args: [getAddress(signer)],
    });
  }

  /**
   * Reads only the fields required to reconcile the current local state.
   *
   * Recovery requires extra reads because the wallet must distinguish pending,
   * failed-but-consumed, and fully successful recovery outcomes.
   */
  async readSnapshotForState(
    state: LocalWalletState,
  ): Promise<OnchainAccountSnapshot> {
    const [isInitialized, isPaused, currentAuthorizedSigner] = await Promise.all([
      this.readIsInitialized(),
      this.readIsPaused(),
      this.readCurrentAuthorizedSigner(),
    ]);

    const snapshot: OnchainAccountSnapshot = {
      isInitialized,
      isPaused,
      currentAuthorizedSigner,
    };

    if (state.status === "PENDING_RECOVERY") {
      if (!state.pendingRecovery) {
        throw new Error("PENDING_RECOVERY without pendingRecovery");
      }

      const [currentRecoverySignerActive, nextRecoverySignerActive] =
        await Promise.all([
          this.readIsActiveRecoverySigner(
            state.pendingRecovery.consumedRecoverySigner,
          ),
          this.readIsActiveRecoverySigner(
            state.pendingRecovery.nextRecoverySigner,
          ),
        ]);

      snapshot.currentRecoverySignerActive = currentRecoverySignerActive;
      snapshot.nextRecoverySignerActive = nextRecoverySignerActive;
    }

    return snapshot;
  }

  /**
   * Reconciles local wallet state with delegated-account storage.
   *
   * Receipts and function return values are not treated as the source of truth.
   */
  async sync(state: LocalWalletState): Promise<SyncResult> {
    if (getAddress(state.delegatedAccount) !== this.delegatedAccount) {
      throw new Error(
        `Client delegatedAccount ${this.delegatedAccount} does not match state delegatedAccount ${state.delegatedAccount}`,
      );
    }

    const snapshot = await this.readSnapshotForState(state);
    return reconcileLocalState(state, snapshot);
  }

  /**
   * Sends a signed Operation through the relayer.
   *
   * The relayer submits the Ethereum transaction; authorization comes from the
   * EIP-712 signature produced by the current auth signer.
   */
  async executeSignedAndRotate(params: {
    operation: Operation;
    signature: Hex;
  }): Promise<Hex> {
    const walletClient = this.requireWalletClient();

    if (!this.relayerAccount) {
      throw new Error("Missing relayer account");
    }

    return walletClient.writeContract({
      account: this.relayerAccount,
      chain: null,
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "executeSignedAndRotate",
      args: [params.operation, params.signature],
    });
  }

  /**
   * Sends a signed RecoveryOperation through the relayer.
   */
  async signedRecovery(params: {
    recoveryOperation: RecoveryOperation;
    signature: Hex;
  }): Promise<Hex> {
    const walletClient = this.requireWalletClient();

    if (!this.relayerAccount) {
      throw new Error("Missing relayer account");
    }

    return walletClient.writeContract({
      account: this.relayerAccount,
      chain: null,
      address: this.delegatedAccount,
      abi: OneTimeSignerAccountAbi,
      functionName: "signedRecovery",
      args: [params.recoveryOperation, params.signature],
    });
  }

  /**
   * Waits for inclusion before sync() re-reads storage and decides the outcome.
   */
  async waitForReceipt(txHash: Hex) {
    return this.publicClient.waitForTransactionReceipt({
      hash: txHash,
      confirmations: 1,
    });
  }
}