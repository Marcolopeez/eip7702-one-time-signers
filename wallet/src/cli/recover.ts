/** Performs signed recovery for a PAUSED delegated account through the SDK. */
import { createWalletFromEnv } from "./walletFromEnv.js";
import { optionalNumberEnv } from "./env.js";

const deadlineSeconds = optionalNumberEnv("DEADLINE_SECONDS", 3600);
const authLookahead = optionalNumberEnv("AUTH_LOOKAHEAD", 50);
const recoveryLookahead = optionalNumberEnv("RECOVERY_LOOKAHEAD", 50);

const { wallet, client } = await createWalletFromEnv({ requireRelayer: true });

const result = await wallet.recover({
  deadlineSeconds,
  authLookahead,
  recoveryLookahead,
});

const receipt = result.receipt as { status: string; blockNumber: bigint };

console.log("Executed signed recovery");
console.log("------------------------");
console.log("next auth signer:     ", result.recoveryOperation.nextAuthorizedSigner);
console.log("next recovery signer: ", result.recoveryOperation.nextRecoverySigner);
console.log("recovery digest:      ", result.recoveryDigest);
console.log("txHash:               ", result.txHash);
console.log("receipt status:       ", receipt.status);
console.log("blockNumber:          ", receipt.blockNumber.toString());
console.log("sync reason:          ", result.syncResult.reason);
console.log("wallet status:        ", result.state.status);
console.log("auth index:           ", result.state.currentAuthIndex);
console.log("auth signer:          ", result.state.currentAuthorizedSigner);
console.log("recovery index:       ", result.state.currentRecoveryIndex);
console.log("recovery signer:      ", result.state.currentRecoverySigner);

if (receipt.status !== "success") {
  throw new Error("Expected signedRecovery transaction to avoid global revert");
}

if (result.syncResult.reason !== "PENDING_RECOVERY_TO_READY") {
  throw new Error(
    `Expected sync reason PENDING_RECOVERY_TO_READY, got ${result.syncResult.reason}`,
  );
}

const recoveryActive = await client.readIsActiveRecoverySigner(
  result.state.currentRecoverySigner,
);

if (!recoveryActive) {
  throw new Error(
    `Expected current recovery signer ${result.state.currentRecoverySigner} to be active on-chain`,
  );
}
