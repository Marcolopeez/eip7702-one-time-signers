/**
 * Small derivation demo for local development.
 *
 * This script prints the first auth and recovery signer addresses derived from
 * a deterministic test mnemonic. It must not be used with production secrets.
 */
import {
  deriveAuthSigner,
  deriveRecoverySigner,
  type DerivationContext,
} from "../crypto/derivation.js";

const mnemonic =
  "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

const context: DerivationContext = {
  mnemonic,
  passphrase: "",
  walletId: "0x1111111111111111111111111111111111111111111111111111111111111111",
  chainId: 31337,
  delegatedAccount: "0x0000000000000000000000000000000000001000",
  implementationAddress: "0x0000000000000000000000000000000000002000",
  accountIndex: 0,
};

// Show that auth and recovery are separate deterministic streams.
for (let i = 0; i < 3; i++) {
  const auth = deriveAuthSigner(context, i);
  const recovery = deriveRecoverySigner(context, i);

  console.log(`auth[${i}]`);
  console.log(`  path:    ${auth.path}`);
  console.log(`  address: ${auth.address}`);

  console.log(`recovery[${i}]`);
  console.log(`  path:    ${recovery.path}`);
  console.log(`  address: ${recovery.address}`);
}
