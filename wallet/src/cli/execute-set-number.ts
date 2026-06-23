/** Executes ExecutionTarget.setNumber(uint256) through the SDK wallet. */
import { encodeFunctionData, parseEther } from "viem";
import { executionTargetAbi } from "../account/executionTargetAbi.js";
import { createWalletFromEnv } from "./walletFromEnv.js";
import {
  optionalEnv,
  optionalNumberEnv,
  requireAddressEnv,
} from "./env.js";

const target = requireAddressEnv("EXECUTION_TARGET_ADDRESS");
const newNumber = BigInt(optionalNumberEnv("NEW_NUMBER", 42));
const deadlineSeconds = optionalNumberEnv("DEADLINE_SECONDS", 3600);
const operationValue = parseEther(optionalEnv("OPERATION_VALUE_ETH", "0"));

const { wallet } = await createWalletFromEnv({ requireRelayer: true });

const data = encodeFunctionData({
  abi: executionTargetAbi,
  functionName: "setNumber",
  args: [newNumber],
});

const result = await wallet.execute({
  target,
  value: operationValue,
  data,
  deadlineSeconds,
});

const receipt = result.receipt as { status: string; blockNumber: bigint };
const pending = result.signedOperation.operation;

console.log("Executed setNumber operation");
console.log("----------------------------");
console.log("target:            ", target);
console.log("newNumber:         ", newNumber.toString());
console.log("value:             ", operationValue.toString());
console.log("next auth signer:  ", pending.nextAuthorizedSigner);
console.log("operation digest:  ", result.operationDigest);
console.log("txHash:            ", result.txHash);
console.log("receipt status:    ", receipt.status);
console.log("blockNumber:       ", receipt.blockNumber.toString());
console.log("sync reason:       ", result.syncResult.reason);
console.log("wallet status:     ", result.state.status);
console.log("auth index:        ", result.state.currentAuthIndex);
console.log("auth signer:       ", result.state.currentAuthorizedSigner);
