/**
 * Dev-only adversarial flow for invalid nextAuthorizedSigner.
 *
 * A production wallet must never sign this payload. The script exists to prove
 * the contract enters PAUSED instead of reverting and reviving the exposed key.
 */
import { encodeFunctionData, getAddress, type Hex } from "viem";
import type { DerivationContext } from "../crypto/derivation.js";
import { deriveAuthSigner } from "../crypto/derivation.js";
import type { Operation } from "../account/types.js";
import { signOperation, hashOperationTypedData } from "../account/eip712.js";
import {
  attachOperationTxHash,
  beginUnsafeOperationSigningForPauseTest,
} from "../account/state.js";
import { EphemeralAccountClient } from "../account/client.js";
import { executionTargetAbi } from "../account/executionTargetAbi.js";
import { JsonLocalStore } from "../storage/localStore.js";
import {
  optionalEnv,
  optionalNumberEnv,
  requireAddressEnv,
  requireEnv,
  requireHexEnv,
} from "./env.js";

// Used only to trigger the emergency pause path.
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

const statePath = optionalEnv("STATE_IN", ".local/state.json");
const rpcUrl = optionalEnv("RPC_URL", "http://127.0.0.1:8545");

const mnemonic = requireEnv("MNEMONIC");
const walletId = requireHexEnv("WALLET_ID");
const relayerPrivateKey = requireHexEnv("RELAYER_PRIVATE_KEY");
const target = requireAddressEnv("EXECUTION_TARGET_ADDRESS");

const newNumber = BigInt(optionalNumberEnv("NEW_NUMBER", 999));
const deadlineSeconds = optionalNumberEnv("DEADLINE_SECONDS", 3600);

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

const beforeSync = await client.sync(state);

if (beforeSync.changed) {
  state = beforeSync.state;
  await store.save(state);
}

if (state.status !== "READY") {
  throw new Error(`Cannot execute invalid operation while state is ${state.status}`);
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

const data = encodeFunctionData({
  abi: executionTargetAbi,
  functionName: "setNumber",
  args: [newNumber],
});

/**
 * Intentionally invalid.
 *
 * A production wallet must never sign this.
 */
const operation: Operation = {
  target,
  value: 0n,
  data,
  nextAuthorizedSigner: ZERO_ADDRESS,
  deadline: BigInt(Math.floor(Date.now() / 1000) + deadlineSeconds),
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
 * Dev-only unsafe transition.
 *
 * We intentionally bypass nextAuthorizedSigner validation to test that:
 * - the contract does not revert globally
 * - the account enters PAUSED
 * - the consumed auth key is not reused locally
 */
// Unsafe transition is explicit so it cannot be confused with normal wallet behavior.
state = beginUnsafeOperationSigningForPauseTest({
  state,
  signedOperation,
  nextAuthIndex: state.currentAuthIndex + 1,
  operationDigest,
  devOnlyReason: "DEV_ONLY: testing invalid nextAuthorizedSigner pause path",
});

await store.save(state);

console.log("Prepared INVALID nextAuthorizedSigner operation");
console.log("------------------------------------------------");
console.log("target:               ", target);
console.log("attempted newNumber:  ", newNumber.toString());
console.log("invalid next signer:  ", ZERO_ADDRESS);
console.log("consumed auth index:  ", state.pendingOperation?.consumedAuthIndex);
console.log("consumed auth signer: ", state.pendingOperation?.consumedAuthSigner);
console.log("operation digest:     ", operationDigest);
console.log("");
console.log("Local state saved with PENDING_OPERATION before broadcasting.");
console.log("");
console.log("This is a DEV-ONLY adversarial test.");
console.log("A production wallet must never sign this operation.");

const txHash: Hex = await client.executeSignedAndRotate({
  operation,
  signature: signedOperation.signature,
});

state = attachOperationTxHash(state, txHash);
await store.save(state);

console.log("");
console.log("Broadcasted invalid executeSignedAndRotate");
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
    "Unexpected: invalid nextAuthorizedSigner should pause the account without globally reverting.",
  );
}

const afterSync = await client.sync(state);
state = afterSync.state;
await store.save(state);

console.log("");
console.log("Post-invalid-operation sync");
console.log("---------------------------");
console.log("reason:      ", afterSync.reason);
console.log("changed:     ", afterSync.changed);
console.log("status:      ", state.status);
console.log("auth index:  ", state.currentAuthIndex);
console.log("auth signer: ", state.currentAuthorizedSigner);

if (state.status !== "PAUSED") {
  throw new Error(
    `Expected account to become PAUSED after invalid nextAuthorizedSigner, got ${state.status}`,
  );
}

if (afterSync.reason !== "PENDING_OPERATION_TO_PAUSED") {
  throw new Error(
    `Expected sync reason PENDING_OPERATION_TO_PAUSED, got ${afterSync.reason}`,
  );
}

console.log("");
console.log("Invalid nextAuthorizedSigner was handled correctly:");
console.log("- transaction did not revert globally");
console.log("- account entered PAUSED");
console.log("- consumed auth key remains burned locally");
console.log("- normal execution is now blocked until recovery");