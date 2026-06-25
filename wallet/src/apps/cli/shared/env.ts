/**
 * Small environment parsing helpers for local CLI scripts.
 *
 * Scripts fail fast when required inputs are missing or malformed, which avoids
 * producing signatures or state files for the wrong account context.
 */
import { getAddress, type Address, type Hex } from "viem";

export function requireEnv(name: string): string {
  const value = process.env[name];

  if (!value || value.trim() === "") {
    throw new Error(`Missing required environment variable: ${name}`);
  }

  return value;
}

export function optionalEnv(name: string, fallback: string): string {
  const value = process.env[name];
  return value && value.trim() !== "" ? value : fallback;
}

/** Parses and checksums an address-valued environment variable. */
export function requireAddressEnv(name: string): Address {
  return getAddress(requireEnv(name));
}

/** Accepts generic 0x-prefixed hex values such as private keys or wallet IDs. */
export function requireHexEnv(name: string): Hex {
  const value = requireEnv(name);

  if (!value.startsWith("0x")) {
    throw new Error(`${name} must be 0x-prefixed hex`);
  }

  return value as Hex;
}

export function optionalNumberEnv(name: string, fallback: number): number {
  const raw = process.env[name];

  if (!raw || raw.trim() === "") {
    return fallback;
  }

  const parsed = Number(raw);

  if (!Number.isSafeInteger(parsed)) {
    throw new Error(`${name} must be a safe integer`);
  }

  return parsed;
}