/** Executes ExecutionTarget.alwaysRevert() and expects rotation to survive. */
import { encodeFunctionData } from "viem";
import { executionTargetAbi } from "../account/executionTargetAbi.js";
import { createWalletFromEnv } from "./walletFromEnv.js";
import {
  optionalNumberEnv,
  requireAddressEnv,
} from "./env.js";

const target = requireAddressEnv("EXECUTION_TARGET_ADDRESS");
const deadlineSeconds = optionalNumberEnv("DEADLINE_SECONDS", 3600);

const { wallet } = await createWalletFromEnv({ requireRelayer: true });

const data = encodeFunctionData({
  abi: executionTargetAbi,
  functionName: "alwaysRevert",
  args: [],
});

const result = await wallet.execute({
  target,
  value: 0n,
  data,
  deadlineSeconds,
});

const receipt = result.receipt as { status: string; blockNumber: bigint };

console.log("Executed target revert operation");
console.log("--------------------------------");
console.log("target:          ", target);
console.log("operation digest:", result.operationDigest);
console.log("txHash:          ", result.txHash);
console.log("receipt status:  ", receipt.status);
console.log("blockNumber:     ", receipt.blockNumber.toString());
console.log("sync reason:     ", result.syncResult.reason);
console.log("wallet status:   ", result.state.status);
console.log("auth index:      ", result.state.currentAuthIndex);
console.log("auth signer:     ", result.state.currentAuthorizedSigner);

if (receipt.status !== "success") {
  throw new Error("Expected target revert to be captured without global revert");
}

if (result.syncResult.reason !== "PENDING_OPERATION_TO_READY") {
  throw new Error(
    `Expected sync reason PENDING_OPERATION_TO_READY, got ${result.syncResult.reason}`,
  );
}
