// bridge/src/e2e/handshake-sig.ts
// Spec: docs/protocol/e2e-handshake.md §"Message flow" (sig_p / sig_a).
import { sign, verify } from "node:crypto";
import { ED25519_SPKI_PREFIX } from "../ed25519-der";

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

/** Ed25519 over the raw canonical transcript bytes (NOT prehashed). */
export function signTranscript(transcript: Buffer, ed25519Seed: Buffer): string {
  const pkcs8 = rawSeedToPkcs8(ed25519Seed);
  return sign(null, transcript, { key: pkcs8, format: "der", type: "pkcs8" }).toString("base64");
}

export function verifyTranscriptSig(
  transcript: Buffer,
  ed25519PubB64: string,
  sigB64: string,
): boolean {
  const pubRaw = Buffer.from(ed25519PubB64, "base64");
  if (pubRaw.length !== 32) return false;
  const spki = Buffer.concat([ED25519_SPKI_PREFIX, pubRaw]);
  try {
    return verify(
      null,
      transcript,
      { key: spki, format: "der", type: "spki" },
      Buffer.from(sigB64, "base64"),
    );
  } catch {
    return false;
  }
}
