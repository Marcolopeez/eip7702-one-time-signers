/**
 * Performs signed recovery for a PAUSED delegated account.
 *
 * The flow burns the active recovery key, installs a fresh auth signer, registers
 * a fresh recovery signer, waits for inclusion, and then reconciles storage.
 */
import { getAddress, type Hex } from "viem";
import type { DerivationContext } from "../crypto/derivation.js";
import {
  deriveRecoverySigner,
} from "../crypto/derivation.js";
import type { RecoveryOperation } from "../account/types.js";
import {
  hashRecoveryOperationTypedData,
  signRecoveryOperation,
} from "../account/eip712.js";
import {
  attachRecoveryTxHash,
  beginRecoverySigning,
} from "../account/state.js";
import { EphemeralAccountClient } from "../account/client.js";
import {
  findNextAvailableRecoverySigner,
  findNextUnusedAuthSigner,
} from "../account/keySelection.js";
import { JsonLocalStore } from "../storage/localStore.js";
import {
  optionalEnv,
  optionalNumberEnv,
  requireEnv,
  requireHexEnv,
} from "./env.js";

const statePath = optionalEnv("STATE_IN", ".local/state.json");
const rpcUrl = optionalEnv("RPC_URL", "http://127.0.0.1:8545");

const mnemonic = requireEnv("MNEMONIC");
const walletId = requireHexEnv("WALLET_ID");
const relayerPrivateKey = requireHexEnv("RELAYER_PRIVATE_KEY");

const deadlineSeconds = optionalNumberEnv("DEADLINE_SECONDS", 3600);
const authLookahead = optionalNumberEnv("AUTH_LOOKAHEAD", 50);
const recoveryLookahead = optionalNumberEnv("RECOVERY_LOOKAHEAD", 50);

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
 * Always sync before producing a recovery signature.
 *
 * If the account already recovered elsewhere, or if the paused state changed,
 * we must discover it before burning a recovery key.
 */
const beforeSync = await client.sync(state);

if (beforeSync.changed) {
  state = beforeSync.state;
  await store.save(state);
}

if (state.status !== "PAUSED") {
  throw new Error(`Cannot recover while state is ${state.status}; expected PAUSED`);
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

const currentRecoverySigner = deriveRecoverySigner(
  derivationContext,
  state.currentRecoveryIndex,
);

if (
  getAddress(currentRecoverySigner.address) !==
  getAddress(state.currentRecoverySigner)
) {
  throw new Error(
    `Derived current recovery signer does not match local state: ${currentRecoverySigner.address} != ${state.currentRecoverySigner}`,
  );
}

// Confirm the local recovery signer is still usable before burning it.
const currentRecoverySignerActive = await client.readIsActiveRecoverySigner(
  currentRecoverySigner.address,
);

if (!currentRecoverySignerActive) {
  throw new Error(
    `Current recovery signer ${currentRecoverySigner.address} is not active on-chain`,
  );
}

/**
 * Important:
 *
 * If the account became PAUSED because auth[i] signed an invalid operation,
 * auth[i] is burned locally. We must not reinstall it.
 *
 * Start from currentAuthIndex + 1 and also skip any locally burned auth index.
 */
const nextAuthSigner = await findNextUnusedAuthSigner({
  context: derivationContext,
  startIndex: state.currentAuthIndex + 1,
  reader: client,
  maxLookahead: authLookahead,
  localBurnedIndices: state.burnedAuthIndices,
});

/**
 * Recovery keys are also one-time keys.
 *
 * The new recovery signer must be:
 * - not active on-chain
 * - not consumed/reserved on-chain
 * - not burned locally
 */
const nextRecoverySigner = await findNextAvailableRecoverySigner({
  context: derivationContext,
  startIndex: state.currentRecoveryIndex + 1,
  reader: client,
  maxLookahead: recoveryLookahead,
  localBurnedIndices: state.burnedRecoveryIndices,
});

// Both auth and recovery streams advance during a successful recovery.
const recoveryOperation: RecoveryOperation = {
  nextAuthorizedSigner: nextAuthSigner.address,
  nextRecoverySigner: nextRecoverySigner.address,
  deadline: BigInt(Math.floor(Date.now() / 1000) + deadlineSeconds),
};

// From this point, recovery[currentRecoveryIndex] is considered burned locally.
const signedRecoveryOperation = await signRecoveryOperation({
  context: {
    chainId: state.chainId,
    delegatedAccount: state.delegatedAccount,
  },
  recoveryOperation,
  privateKey: currentRecoverySigner.privateKey,
});

const recoveryDigest = hashRecoveryOperationTypedData(
  {
    chainId: state.chainId,
    delegatedAccount: state.delegatedAccount,
  },
  recoveryOperation,
);

/**
 * Security-critical point:
 *
 * From this line onward, recovery[currentRecoveryIndex] is burned locally,
 * even if the transaction is not mined or recovery fails.
 */
// Persist PENDING_RECOVERY before broadcasting, matching the one-time key model.
state = beginRecoverySigning({
  state,
  signedRecoveryOperation,
  nextAuthIndex: nextAuthSigner.index,
  nextRecoveryIndex: nextRecoverySigner.index,
  recoveryDigest,
});

await store.save(state);

console.log("Prepared signed recovery");
console.log("------------------------");
console.log("consumed recovery index:  ", state.pendingRecovery?.consumedRecoveryIndex);
console.log("consumed recovery signer: ", state.pendingRecovery?.consumedRecoverySigner);
console.log("next auth index:          ", state.pendingRecovery?.nextAuthIndex);
console.log("next auth signer:         ", state.pendingRecovery?.nextAuthorizedSigner);
console.log("next recovery index:      ", state.pendingRecovery?.nextRecoveryIndex);
console.log("next recovery signer:     ", state.pendingRecovery?.nextRecoverySigner);
console.log("recovery digest:          ", recoveryDigest);
console.log("");
console.log("Local state saved with PENDING_RECOVERY before broadcasting.");

const txHash: Hex = await client.signedRecovery({
  recoveryOperation,
  signature: signedRecoveryOperation.signature,
});

state = attachRecoveryTxHash(state, txHash);
await store.save(state);

console.log("");
console.log("Broadcasted signedRecovery");
console.log("--------------------------");
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
    "Unexpected: signedRecovery should handle expected recovery errors without globally reverting.",
  );
}

/**
 * Do not infer recovery success from receipt.status.
 *
 * The source of truth is:
 * - isPaused()
 * - currentAuthorizedSigner()
 * - isActiveRecoverySigner(nextRecoverySigner)
 */
const afterSync = await client.sync(state);
state = afterSync.state;
await store.save(state);

console.log("");
console.log("Post-recovery sync");
console.log("------------------");
console.log("reason:          ", afterSync.reason);
console.log("changed:         ", afterSync.changed);
console.log("status:          ", state.status);
console.log("auth index:      ", state.currentAuthIndex);
console.log("auth signer:     ", state.currentAuthorizedSigner);
console.log("recovery index:  ", state.currentRecoveryIndex);
console.log("recovery signer: ", state.currentRecoverySigner);

if (state.status !== "READY") {
  throw new Error(`Expected account to become READY after recovery, got ${state.status}`);
}

if (afterSync.reason !== "PENDING_RECOVERY_TO_READY") {
  throw new Error(
    `Expected sync reason PENDING_RECOVERY_TO_READY, got ${afterSync.reason}`,
  );
}

const nextRecoveryActive = await client.readIsActiveRecoverySigner(
  state.currentRecoverySigner,
);

if (!nextRecoveryActive) {
  throw new Error(
    `Expected current recovery signer ${state.currentRecoverySigner} to be active on-chain`,
  );
}

console.log("");
console.log("Recovery completed correctly:");
console.log("- old recovery key was burned locally");
console.log("- new auth signer was installed");
console.log("- new recovery signer was installed");
console.log("- account returned to READY");