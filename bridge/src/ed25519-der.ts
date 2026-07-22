/** SPKI DER prefix for a raw 32-byte Ed25519 public key. */
export const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
/** Single NUL byte used as the field separator in canonical sig bodies. */
export const NUL = Buffer.from([0]);
