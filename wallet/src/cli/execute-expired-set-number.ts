/** Executes an expired setNumber operation; rotation should still advance. */
import { encodeFunctionData } from "viem";
import { executionTargetAbi } from "../account/executionTargetAbi.js";
import { createWalletFromEnv } from "./walletFromEnv.js";
import {
  optionalNumberEnv,
  requireAddressEnv,
} from "./env.js";

const target = requireAddressEnv("EXECUTION_TARGET_ADDRESS");
const newNumber = BigInt(optionalNumberEnv("NEW_NUMBER", 777));

const { wallet } = await createWalletFromEnv({ requireRelayer: true });

const data = encodeFunctionData({
  abi: executionTargetAbi,
  functionName: "setNumber",
  args: [newNumber],
});

const result = await wallet.execute({
  target,
  value: 0n,
  data,
  deadline: BigInt(Math.floor(Date.now() / 1000) - 1),
});

const receipt = result.receipt as { status: string; blockNumber: bigint };

console.log("Executed expired setNumber operation");
console.log("------------------------------------");
console.log("target:          ", target);
console.log("newNumber:       ", newNumber.toString());
console.log("operation digest:", result.operationDigest);
console.log("txHash:          ", result.txHash);
console.log("receipt status:  ", receipt.status);
console.log("blockNumber:     ", receipt.blockNumber.toString());
console.log("sync reason:     ", result.syncResult.reason);
console.log("wallet status:   ", result.state.status);
console.log("auth index:      ", result.state.currentAuthIndex);
console.log("auth signer:     ", result.state.currentAuthorizedSigner);

if (receipt.status !== "success") {
  throw new Error("Expected expired operation to avoid global revert");
}

if (result.syncResult.reason !== "PENDING_OPERATION_TO_READY") {
  throw new Error(
    `Expected sync reason PENDING_OPERATION_TO_READY, got ${result.syncResult.reason}`,
  );
}
