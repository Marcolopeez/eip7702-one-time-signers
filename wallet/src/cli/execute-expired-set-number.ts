/**
 * Executes an intentionally expired operation with a valid next auth signer.
 *
 * The target call should not execute, but the observed auth signature still
 * causes key rotation and local key burning.
 */
import { encodeFunctionData, getAddress, type Hex } from "viem";
import type { DerivationContext } from "../crypto/derivation.js";
import { deriveAuthSigner } from "../crypto/derivation.js";
import type { Operation } from "../account/types.js";
import { signOperation, hashOperationTypedData } from "../account/eip712.js";
import {
  attachOperationTxHash,
  beginOperationSigning,
} from "../account/state.js";
import { EphemeralAccountClient } from "../account/client.js";
import { findNextUnusedAuthSigner } from "../account/keySelection.js";
import { executionTargetAbi } from "../account/executionTargetAbi.js";
import { JsonLocalStore } from "../storage/localStore.js";
import {
  optionalEnv,
  optionalNumberEnv,
  requireAddressEnv,
  requireEnv,
  requireHexEnv,
} from "./env.js";

const statePath = optionalEnv("STATE_IN", ".local/state.json");
const rpcUrl = optionalEnv("RPC_URL", "http://127.0.0.1:8545");

const mnemonic = requireEnv("MNEMONIC");
const walletId = requireHexEnv("WALLET_ID");
const relayerPrivateKey = requireHexEnv("RELAYER_PRIVATE_KEY");
const target = requireAddressEnv("EXECUTION_TARGET_ADDRESS");

const newNumber = BigInt(optionalNumberEnv("NEW_NUMBER", 777));

const store = new JsonLocalStore(statePath);
let state = await store.load();

if (!state) {
  throw new Error(`No wallet state found at ${statePath}`);
}

const client = new EphemeralAccountClient({
  rpcUrl,
  chainId: state.chainId,
  delegatedAccount: state.delegatedAccount,
  relayerPrivateKey,
});

/**
 * Always sync before producing a new signature.
 */
const beforeSync = await client.sync(state);

if (beforeSync.changed) {
  state = beforeSync.state;
  await store.save(state);
}

if (state.status !== "READY") {
  throw new Error(`Cannot execute operation while state is ${state.status}`);
}

const derivationContext: DerivationContext = {
  mnemonic,
  passphrase: optionalEnv("BIP39_PASSPHRASE", ""),
  walletId,
  chainId: state.chainId,
  delegatedAccount: state.delegatedAccount,
  implementationAddress: state.implementationAddress,
  accountIndex: state.accountIndex,
};

const currentAuthSigner = deriveAuthSigner(
  derivationContext,
  state.currentAuthIndex,
);

if (getAddress(currentAuthSigner.address) !== getAddress(state.currentAuthorizedSigner)) {
  throw new Error(
    `Derived current auth signer does not match local state: ${currentAuthSigner.address} != ${state.currentAuthorizedSigner}`,
  );
}

// Even expired operations must rotate to a valid, unused next signer.
const nextAuthSigner = await findNextUnusedAuthSigner({
  context: derivationContext,
  startIndex: state.currentAuthIndex + 1,
  reader: client,
});

const data = encodeFunctionData({
  abi: executionTargetAbi,
  functionName: "setNumber",
  args: [newNumber],
});

/**
 * Intentionally expired.
 *
 * We use now - 1 second. The operation is already expired before broadcast.
 */
const expiredDeadline = BigInt(Math.floor(Date.now() / 1000) - 1);

const operation: Operation = {
  target,
  value: 0n,
  data,
  nextAuthorizedSigner: nextAuthSigner.address,
  deadline: expiredDeadline,
};

const signedOperation = await signOperation({
  context: {
    chainId: state.chainId,
    delegatedAccount: state.delegatedAccount,
  },
  operation,
  privateKey: currentAuthSigner.privateKey,
});

const operationDigest = hashOperationTypedData(
  {
    chainId: state.chainId,
    delegatedAccount: state.delegatedAccount,
  },
  operation,
);

/**
 * Even though the operation is expired, the signature has been produced.
 * Therefore auth[currentAuthIndex] is burned locally.
 */
// The operation is expired, but the signature has still exposed auth[i].
state = beginOperationSigning({
  state,
  signedOperation,
  nextAuthIndex: nextAuthSigner.index,
  operationDigest,
});

await store.save(state);

console.log("Prepared expired setNumber operation");
console.log("------------------------------------");
console.log("target:               ", target);
console.log("newNumber:            ", newNumber.toString());
console.log("expired deadline:     ", expiredDeadline.toString());
console.log("consumed auth index:  ", state.pendingOperation?.consumedAuthIndex);
console.log("consumed auth signer: ", state.pendingOperation?.consumedAuthSigner);
console.log("next auth index:      ", state.pendingOperation?.nextAuthIndex);
console.log("next auth signer:     ", state.pendingOperation?.nextAuthorizedSigner);
console.log("operation digest:     ", operationDigest);
console.log("");
console.log("Local state saved with PENDING_OPERATION before broadcasting.");

const txHash: Hex = await client.executeSignedAndRotate({
  operation,
  signature: signedOperation.signature,
});

state = attachOperationTxHash(state, txHash);
await store.save(state);

console.log("");
console.log("Broadcasted expired executeSignedAndRotate");
console.log("------------------------------------------");
console.log("txHash:", txHash);

const receipt = await client.waitForReceipt(txHash);

console.log("");
console.log("Receipt");
console.log("-------");
console.log("status:      ", receipt.status);
console.log("blockNumber: ", receipt.blockNumber.toString());

if (receipt.status !== "success") {
  console.warn("");
  console.warn(
    "Unexpected: expired operation should be handled without globally reverting.",
  );
}

const afterSync = await client.sync(state);
state = afterSync.state;
await store.save(state);

console.log("");
console.log("Post-expired-operation sync");
console.log("---------------------------");
console.log("reason:      ", afterSync.reason);
console.log("changed:     ", afterSync.changed);
console.log("status:      ", state.status);
console.log("auth index:  ", state.currentAuthIndex);
console.log("auth signer: ", state.currentAuthorizedSigner);

if (state.status !== "READY") {
  throw new Error(
    `Expected account to return to READY after expired operation, got ${state.status}`,
  );
}

if (afterSync.reason !== "PENDING_OPERATION_TO_READY") {
  throw new Error(
    `Expected sync reason PENDING_OPERATION_TO_READY, got ${afterSync.reason}`,
  );
}

console.log("");
console.log("Expired operation was handled correctly:");
console.log("- transaction did not revert globally");
console.log("- auth signer rotated");
console.log("- target call was skipped by contract logic");
console.log("- local state returned to READY");