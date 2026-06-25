/**
 * Deterministic signer derivation for the one-time signer wallet.
 *
 * The wallet manages independent one-time ECDSA signer streams. The auth stream
 * controls normal execution; the recovery stream restores the account when the
 * contract enters the paused state.
 */
import { HDKey } from "@scure/bip32";
import { mnemonicToSeedSync, validateMnemonic } from "@scure/bip39";
import { wordlist } from "@scure/bip39/wordlists/english.js";
import { hkdf } from "@noble/hashes/hkdf.js";
import { sha256 } from "@noble/hashes/sha2.js";
import { utf8ToBytes } from "@noble/hashes/utils.js";
import { getAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { assertHex32, bytesToHexPrefixed, hexToBytes } from "./hex.js";

export type SignerStream = "auth" | "recovery";

export type DerivationContext = {
  /**
   * BIP-39 mnemonic.
   *
   * In production this should be 24 words.
   * Tests may use a standard 12-word test mnemonic.
   */
  mnemonic: string;

  /**
   * Optional BIP-39 passphrase.
   *
   * For local tests, use "".
   */
  passphrase?: string;

  /**
   * Per-install wallet id.
   *
   * Important:
   * - used for auth stream separation
   * - not used for recovery stream
   */
  walletId: Hex;

  /**
   * Chain where the delegated account exists.
   */
  chainId: number | bigint;

  /**
   * The EOA address executing delegated code under EIP-7702.
   *
   * This is the EIP-712 verifyingContract.
   */
  delegatedAccount: Address;

  /**
   * The implementation contract address delegated to by the EOA.
   */
  implementationAddress: Address;

  /**
   * Logical account index.
   *
   * Similar in spirit to BIP-44 account', but this is our own purpose.
   */
  accountIndex: number;
};

export type DerivedSigner = {
  stream: SignerStream;
  index: number;
  path: string;
  privateKey: Hex;
  address: Address;
};

// Private experimental purpose for this EIP-7702 account prototype.
const PURPOSE = 7702;
const ETHEREUM_COIN_TYPE = 60;

// Stream separation is also reflected in the BIP-32 path.
const STREAM_PATH_INDEX: Record<SignerStream, number> = {
  auth: 0,
  recovery: 1,
};

function assertSafeDerivationIndex(index: number, label: string): void {
  if (!Number.isInteger(index)) {
    throw new Error(`${label} must be an integer`);
  }

  if (index < 0) {
    throw new Error(`${label} must be non-negative`);
  }

  /**
   * Path indices are written before the hardened offset is applied by the BIP-32
   * library. Keeping them below 2^31 ensures `i'` is a valid hardened index.
   */
  if (index >= 2 ** 31) {
    throw new Error(`${label} must be lower than 2^31`);
  }
}

function hardened(value: number): string {
  assertSafeDerivationIndex(value, "hardened path index");
  return `${value}'`;
}

/**
 * Builds a hardened-only path for a signer leaf.
 *
 * No xpub/watch-only derivation is supported because every leaf is a signing
 * key that may become exposed after a single ECDSA signature.
 */
function buildPath(stream: SignerStream, accountIndex: number, index: number): string {
  assertSafeDerivationIndex(accountIndex, "accountIndex");
  assertSafeDerivationIndex(index, "signer index");

  const streamIndex = STREAM_PATH_INDEX[stream];

  return [
    "m",
    hardened(PURPOSE),
    hardened(ETHEREUM_COIN_TYPE),
    hardened(accountIndex),
    hardened(streamIndex),
    hardened(index),
  ].join("/");
}

function buildAccountContext(context: DerivationContext): Uint8Array {
  const delegatedAccount = getAddress(context.delegatedAccount);
  const implementationAddress = getAddress(context.implementationAddress);

  /**
   * This context intentionally binds derived keys to:
   * - this chain
   * - this delegated EOA
   * - this implementation
   * - this account index
   *
   * This avoids accidentally reusing the same one-time signer
   * across different accounts or chains.
   */
  const encoded = [
    "OneTimeSignerAccount:v1",
    `chainId:${context.chainId.toString()}`,
    `delegatedAccount:${delegatedAccount}`,
    `implementationAddress:${implementationAddress}`,
    `accountIndex:${context.accountIndex.toString()}`,
  ].join("|");

  return utf8ToBytes(encoded);
}

function deriveRootSeed(context: DerivationContext): Uint8Array {
  if (!validateMnemonic(context.mnemonic, wordlist)) {
    throw new Error("Invalid BIP-39 mnemonic");
  }

  return mnemonicToSeedSync(context.mnemonic, context.passphrase ?? "");
}

function deriveWalletRoot(rootSeed: Uint8Array, walletId: Hex): Uint8Array {
  assertHex32(walletId, "walletId");

  /**
   * The wallet root is installation-bound.
   *
   * If walletId is lost, this auth stream is intentionally not recoverable.
   * Recovery should rotate the on-chain account to a new wallet stream.
   */
  return hkdf(
    sha256,
    rootSeed,
    hexToBytes(walletId),
    utf8ToBytes("OneTimeSignerAccount:v1:wallet-root"),
    64,
  );
}

function deriveRecoveryRoot(rootSeed: Uint8Array): Uint8Array {
  /**
   * The recovery root is not walletId-bound.
   *
   * This means mnemonic + passphrase are enough to recover.
   */
  return hkdf(
    sha256,
    rootSeed,
    utf8ToBytes("OneTimeSignerAccount:v1:recovery-root:salt"),
    utf8ToBytes("OneTimeSignerAccount:v1:recovery-root"),
    64,
  );
}

/**
 * Derives the stream-specific BIP-32 master seed.
 *
 * HKDF is used here for explicit domain separation before BIP-32 leaf
 * derivation. Auth and recovery therefore live in different key spaces.
 */
function deriveStreamMasterSeed(context: DerivationContext, stream: SignerStream): Uint8Array {
  const rootSeed = deriveRootSeed(context);
  const accountContext = buildAccountContext(context);

  const streamRoot =
    stream === "auth"
      ? deriveWalletRoot(rootSeed, context.walletId)
      : deriveRecoveryRoot(rootSeed);

  return hkdf(
    sha256,
    streamRoot,
    accountContext,
    utf8ToBytes(`OneTimeSignerAccount:v1:${stream}:bip32-master-seed`),
    64,
  );
}

function privateKeyFromHDKey(key: HDKey): Hex {
  if (!key.privateKey) {
    throw new Error("Derived HD key does not contain a private key");
  }

  if (key.privateKey.length !== 32) {
    throw new Error("Derived private key must be 32 bytes");
  }

  return bytesToHexPrefixed(key.privateKey);
}

/**
 * Derives a one-time signer for a given stream and index.
 *
 * The returned private key should be used only by the signing layer and burned
 * according to the local state machine after producing a signature.
 */
export function deriveSigner(
  context: DerivationContext,
  stream: SignerStream,
  index: number,
): DerivedSigner {
  const path = buildPath(stream, context.accountIndex, index);
  const masterSeed = deriveStreamMasterSeed(context, stream);

  const root = HDKey.fromMasterSeed(masterSeed);
  const child = root.derive(path);

  const privateKey = privateKeyFromHDKey(child);
  const account = privateKeyToAccount(privateKey);

  return {
    stream,
    index,
    path,
    privateKey,
    address: account.address,
  };
}

export function deriveAuthSigner(context: DerivationContext, index: number): DerivedSigner {
  return deriveSigner(context, "auth", index);
}

export function deriveRecoverySigner(context: DerivationContext, index: number): DerivedSigner {
  return deriveSigner(context, "recovery", index);
}
