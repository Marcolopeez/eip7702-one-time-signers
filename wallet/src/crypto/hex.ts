/**
 * Minimal hex/byte helpers used by the derivation layer.
 *
 * viem's Hex type is a compile-time aid, so this module also performs the few
 * runtime checks needed before feeding values into cryptographic functions.
 */
import type { Hex } from "viem";

export function bytesToHexPrefixed(bytes: Uint8Array): Hex {
  let hex = "0x";

  for (const byte of bytes) {
    hex += byte.toString(16).padStart(2, "0");
  }

  return hex as Hex;
}

export function hexToBytes(hex: Hex): Uint8Array {
  const clean = hex.startsWith("0x") ? hex.slice(2) : hex;

  if (clean.length % 2 !== 0) {
    throw new Error("Invalid hex string length");
  }

  if (!/^[0-9a-fA-F]*$/.test(clean)) {
    throw new Error("Invalid hex string");
  }

  const bytes = new Uint8Array(clean.length / 2);

  for (let i = 0; i < bytes.length; i++) {
    const start = i * 2;
    bytes[i] = Number.parseInt(clean.slice(start, start + 2), 16);
  }

  return bytes;
}

/**
 * Ensures a hex value is exactly 32 bytes.
 *
 * Used for walletId because it is fed directly into HKDF as domain-separating
 * installation entropy.
 */
export function assertHex32(value: Hex, label: string): void {
  const clean = value.startsWith("0x") ? value.slice(2) : value;

  if (clean.length !== 64) {
    throw new Error(`${label} must be 32 bytes`);
  }

  if (!/^[0-9a-fA-F]*$/.test(clean)) {
    throw new Error(`${label} must be valid hex`);
  }
}
