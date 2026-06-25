import { getAddress, type Address, type Hex } from "viem";
import type { LocalWalletState } from "../../../protocol/one-time-signer-account/state.js";
import type {
  ExtensionWalletSettings,
  ExtensionWalletSettingsInput,
} from "../messaging/types.js";

export type ValidationResult<T> =
  | { ok: true; value: T }
  | { ok: false; error: string };

const PRIVATE_KEY_RE = /^0x[0-9a-fA-F]{64}$/;
const HEX_32_RE = /^0x[0-9a-fA-F]{64}$/;

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSafeNonNegativeInteger(value: unknown): value is number {
  return Number.isSafeInteger(value) && Number(value) >= 0;
}

function validatePrivateKey(value: string, label: string): ValidationResult<Hex> {
  const trimmed = value.trim();

  if (!PRIVATE_KEY_RE.test(trimmed)) {
    return {
      ok: false,
      error: `${label} must be a 32-byte 0x-prefixed private key`,
    };
  }

  return { ok: true, value: trimmed as Hex };
}

function validateHex32(value: unknown, label: string): ValidationResult<Hex> {
  if (typeof value !== "string" || !HEX_32_RE.test(value)) {
    return {
      ok: false,
      error: `${label} must be a 32-byte 0x-prefixed hex string`,
    };
  }

  return { ok: true, value: value as Hex };
}

function validateAddress(value: unknown, label: string): ValidationResult<Address> {
  if (typeof value !== "string") {
    return { ok: false, error: `${label} must be an address` };
  }

  try {
    return { ok: true, value: getAddress(value) };
  } catch {
    return { ok: false, error: `${label} must be a valid address` };
  }
}

function validateOptionalAddress(
  value: string | undefined,
  label: string,
): ValidationResult<Address | undefined> {
  if (value === undefined || value.trim() === "") {
    return { ok: true, value: undefined };
  }

  return validateAddress(value, label);
}

export function validateSettingsInput(
  input: ExtensionWalletSettingsInput,
  previous: ExtensionWalletSettings | null,
): ValidationResult<ExtensionWalletSettings> {
  const rpcUrl = input.rpcUrl.trim();

  if (rpcUrl === "") {
    return { ok: false, error: "RPC URL is required" };
  }

  try {
    const parsed = new URL(rpcUrl);

    if (!["http:", "https:"].includes(parsed.protocol)) {
      return { ok: false, error: "RPC URL must use http or https" };
    }
  } catch {
    return { ok: false, error: "RPC URL must be a valid URL" };
  }

  const mnemonic = input.mnemonic?.trim() || previous?.mnemonic;

  if (!mnemonic) {
    return {
      ok: false,
      error: "Mnemonic is required the first time you save settings",
    };
  }

  const relayerPrivateKeyRaw =
    input.relayerPrivateKey?.trim() || previous?.relayerPrivateKey;

  if (!relayerPrivateKeyRaw) {
    return {
      ok: false,
      error: "Relayer private key is required the first time you save settings",
    };
  }

  const relayerPrivateKey = validatePrivateKey(
    relayerPrivateKeyRaw,
    "Relayer private key",
  );

  if (!relayerPrivateKey.ok) {
    return relayerPrivateKey;
  }

  const executionTargetAddress = validateOptionalAddress(
    input.executionTargetAddress,
    "ExecutionTarget address",
  );

  if (!executionTargetAddress.ok) {
    return executionTargetAddress;
  }

  const settings: ExtensionWalletSettings = {
    mnemonic,
    rpcUrl,
    relayerPrivateKey: relayerPrivateKey.value,
    ...(input.passphrase !== undefined && input.passphrase !== ""
      ? { passphrase: input.passphrase }
      : previous?.passphrase
        ? { passphrase: previous.passphrase }
        : {}),
    ...(executionTargetAddress.value !== undefined
      ? { executionTargetAddress: executionTargetAddress.value }
      : previous?.executionTargetAddress
        ? { executionTargetAddress: previous.executionTargetAddress }
        : {}),
  };

  return { ok: true, value: settings };
}

export function parseLocalWalletStateJson(
  stateJson: string,
): ValidationResult<LocalWalletState> {
  let parsed: unknown;

  try {
    parsed = JSON.parse(stateJson);
  } catch {
    return { ok: false, error: "State JSON is not valid JSON" };
  }

  if (!isObject(parsed)) {
    return { ok: false, error: "State JSON must be an object" };
  }

  const schemaVersion = parsed.schemaVersion;

  if (schemaVersion !== 1) {
    return { ok: false, error: "Unsupported state schemaVersion" };
  }

  if (!isSafeNonNegativeInteger(parsed.chainId)) {
    return { ok: false, error: "state.chainId must be a safe integer" };
  }

  if (!isSafeNonNegativeInteger(parsed.accountIndex)) {
    return { ok: false, error: "state.accountIndex must be a safe integer" };
  }

  if (!isSafeNonNegativeInteger(parsed.currentAuthIndex)) {
    return { ok: false, error: "state.currentAuthIndex must be a safe integer" };
  }

  if (!isSafeNonNegativeInteger(parsed.currentRecoveryIndex)) {
    return {
      ok: false,
      error: "state.currentRecoveryIndex must be a safe integer",
    };
  }

  const walletId = validateHex32(parsed.walletId, "state.walletId");
  if (!walletId.ok) return walletId;

  const delegatedAccount = validateAddress(
    parsed.delegatedAccount,
    "state.delegatedAccount",
  );
  if (!delegatedAccount.ok) return delegatedAccount;

  const implementationAddress = validateAddress(
    parsed.implementationAddress,
    "state.implementationAddress",
  );
  if (!implementationAddress.ok) return implementationAddress;

  const currentAuthorizedSigner = validateAddress(
    parsed.currentAuthorizedSigner,
    "state.currentAuthorizedSigner",
  );
  if (!currentAuthorizedSigner.ok) return currentAuthorizedSigner;

  const currentRecoverySigner = validateAddress(
    parsed.currentRecoverySigner,
    "state.currentRecoverySigner",
  );
  if (!currentRecoverySigner.ok) return currentRecoverySigner;

  const status = parsed.status;

  if (
    status !== "READY" &&
    status !== "PENDING_OPERATION" &&
    status !== "PAUSED" &&
    status !== "PENDING_RECOVERY"
  ) {
    return { ok: false, error: "state.status is invalid" };
  }

  if (!Array.isArray(parsed.burnedAuthIndices)) {
    return { ok: false, error: "state.burnedAuthIndices must be an array" };
  }

  if (!Array.isArray(parsed.burnedRecoveryIndices)) {
    return {
      ok: false,
      error: "state.burnedRecoveryIndices must be an array",
    };
  }

  for (const index of parsed.burnedAuthIndices) {
    if (!isSafeNonNegativeInteger(index)) {
      return {
        ok: false,
        error: "state.burnedAuthIndices must contain safe integers",
      };
    }
  }

  for (const index of parsed.burnedRecoveryIndices) {
    if (!isSafeNonNegativeInteger(index)) {
      return {
        ok: false,
        error: "state.burnedRecoveryIndices must contain safe integers",
      };
    }
  }

  const normalized: LocalWalletState = {
    ...(parsed as LocalWalletState),
    walletId: walletId.value,
    delegatedAccount: delegatedAccount.value,
    implementationAddress: implementationAddress.value,
    currentAuthorizedSigner: currentAuthorizedSigner.value,
    currentRecoverySigner: currentRecoverySigner.value,
  };

  return { ok: true, value: normalized };
}