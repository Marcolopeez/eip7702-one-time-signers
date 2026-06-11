/**
 * Prepares deterministic initialization data for a local EIP-7702 account.
 *
 * It derives auth[0] and recovery[0] for the authority EOA and writes both a
 * JSON file for wallet scripts and an env file for Foundry initialization.
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { privateKeyToAccount } from "viem/accounts";
import type { DerivationContext } from "../crypto/derivation.js";
import {
  deriveAuthSigner,
  deriveRecoverySigner,
} from "../crypto/derivation.js";
import {
  optionalEnv,
  optionalNumberEnv,
  requireAddressEnv,
  requireEnv,
  requireHexEnv,
} from "./env.js";

const outPath = optionalEnv("INIT_OUT", ".local/init.json");
const envOutPath = optionalEnv("INIT_ENV_OUT", ".local/init.env");

const mnemonic = requireEnv("MNEMONIC");
const walletId = requireHexEnv("WALLET_ID");
const authorityPrivateKey = requireHexEnv("AUTHORITY_PRIVATE_KEY");
const implementationAddress = requireAddressEnv("IMPLEMENTATION_ADDRESS");

const chainId = optionalNumberEnv("CHAIN_ID", 31337);
const accountIndex = optionalNumberEnv("ACCOUNT_INDEX", 0);

// The delegated account address is the native EOA controlled by AUTHORITY_PRIVATE_KEY.
const authority = privateKeyToAccount(authorityPrivateKey);

const derivationContext: DerivationContext = {
  mnemonic,
  passphrase: optionalEnv("BIP39_PASSPHRASE", ""),
  walletId,
  chainId,
  delegatedAccount: authority.address,
  implementationAddress,
  accountIndex,
};

// These first signers must match the values passed to initialize().
const auth0 = deriveAuthSigner(derivationContext, 0);
const recovery0 = deriveRecoverySigner(derivationContext, 0);

const init = {
  chainId,
  accountIndex,
  delegatedAccount: authority.address,
  implementationAddress,
  firstAuthorizedSigner: auth0.address,
  firstRecoverySigner: recovery0.address,
  authIndex: 0,
  recoveryIndex: 0,
};

await mkdir(dirname(outPath), { recursive: true });
await writeFile(outPath, `${JSON.stringify(init, null, 2)}\n`, "utf8");

const envFile = [
  `export CHAIN_ID=${chainId}`,
  `export ACCOUNT_INDEX=${accountIndex}`,
  `export DELEGATED_ACCOUNT=${authority.address}`,
  `export IMPLEMENTATION_ADDRESS=${implementationAddress}`,
  `export FIRST_AUTHORIZED_SIGNER=${auth0.address}`,
  `export FIRST_RECOVERY_SIGNER=${recovery0.address}`,
].join("\n");

await mkdir(dirname(envOutPath), { recursive: true });
await writeFile(envOutPath, `${envFile}\n`, "utf8");

console.log("Prepared local EIP-7702 initialization");
console.log("--------------------------------------");
console.log("delegatedAccount:       ", authority.address);
console.log("implementationAddress:  ", implementationAddress);
console.log("firstAuthorizedSigner:  ", auth0.address);
console.log("firstRecoverySigner:    ", recovery0.address);
console.log("");
console.log(`Wrote ${outPath}`);
console.log(`Wrote ${envOutPath}`);