import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";

// Ed25519 PKCS8 prefix (RFC 8410): SEQUENCE { INTEGER 0, AlgorithmIdentifier
// { 1.3.101.112 }, OCTET STRING { OCTET STRING { seed32 } } }
const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

// SubjectPublicKeyInfo prefix for a raw 32-byte Ed25519 public key.
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

/**
 * Convert a 32-byte raw Ed25519 private seed to PKCS8 DER form for
 * `crypto.sign`.
 */
export function rawSeedToPkcs8(seed: Uint8Array | Buffer): Buffer {
  if (seed.length !== 32) {
    throw new Error(`Ed25519 seed must be 32 bytes, got ${seed.length}`);
  }
  return Buffer.concat([ED25519_PKCS8_PREFIX, Buffer.from(seed)]);
}

/** Ed25519 sign `data` with a raw 32-byte seed (base64). Shared by the hello
 *  proof and any signed frame. */
export function signEd25519(seedB64: string, data: Uint8Array): string {
  const key = createPrivateKey({
    key: rawSeedToPkcs8(Buffer.from(seedB64, "base64")),
    format: "der",
    type: "pkcs8",
  });
  return sign(null, data, key).toString("base64");
}

/** Verify an Ed25519 signature against a raw 32-byte public key (base64).
 *  Malformed keys or signatures are a failed verification, never a throw. */
export function verifyEd25519(pubB64: string, data: Uint8Array, sigB64: string): boolean {
  try {
    const pub = Buffer.from(pubB64, "base64");
    const sig = Buffer.from(sigB64, "base64");
    if (pub.length !== 32 || sig.length !== 64) return false;
    const key = createPublicKey({ key: Buffer.concat([ED25519_SPKI_PREFIX, pub]), format: "der", type: "spki" });
    return verify(null, data, key, sig);
  } catch {
    return false;
  }
}
