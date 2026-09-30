// Ed25519 PKCS8 prefix (RFC 8410): SEQUENCE { INTEGER 0, AlgorithmIdentifier
// { 1.3.101.112 }, OCTET STRING { OCTET STRING { seed32 } } }
const ED25519_PKCS8_PREFIX = Buffer.from(
  "302e020100300506032b657004220420",
  "hex",
);

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
