import { sign } from "node:crypto";

/**
 * Inputs to the pair-approval signature.
 *
 * Encoding contract: `phonePubkey` and `nonce` are standard base64
 * (RFC 4648 §4, padded). The signature returned by {@link signPairApproval}
 * is also standard base64. Downstream consumers (relay verification, phone
 * Dart client) must match this encoding exactly.
 */
export interface PairApprovalArgs {
  agentDeviceId: string;
  phonePubkey: string; // standard base64 (RFC 4648 §4, padded)
  phoneDeviceId: string;
  nonce: string; // standard base64 (RFC 4648 §4, padded)
  expiresAt: string; // ISO-8601
}

const DOMAIN = "antgrid.pair-approval.v1";
const NUL = Buffer.from([0]);

/**
 * Build the canonical pair-approval signature body.
 *
 * Layout:
 *   "antgrid.pair-approval.v1" || 0x00 ||
 *   agentDeviceId (utf8)    || 0x00 ||
 *   base64Decode(phonePubkey) || 0x00 ||
 *   phoneDeviceId (utf8)    || 0x00 ||
 *   base64Decode(nonce)     || 0x00 ||
 *   expiresAt (utf8, ISO-8601, no trailing 0x00)
 *
 * The domain prefix provides separation from other Ed25519 signatures (e.g.
 * the relay challenge-response) signed by the same agent key.
 */
export function buildPairApprovalSigBody(args: PairApprovalArgs): Uint8Array {
  return Buffer.concat([
    Buffer.from(DOMAIN, "utf8"),
    NUL,
    Buffer.from(args.agentDeviceId, "utf8"),
    NUL,
    Buffer.from(args.phonePubkey, "base64"),
    NUL,
    Buffer.from(args.phoneDeviceId, "utf8"),
    NUL,
    Buffer.from(args.nonce, "base64"),
    NUL,
    Buffer.from(args.expiresAt, "utf8"),
  ]);
}

/**
 * Sign a pair-approval payload with the agent's Ed25519 key.
 *
 * Accepts a 32-byte raw Ed25519 seed (as produced by stripping the PKCS8
 * prefix off a generated private key) and returns a base64-encoded signature
 * along with the canonical sigBody so the caller can attach both to the
 * approval message.
 */
export function signPairApproval(
  args: PairApprovalArgs & { agentEd25519Priv: Uint8Array | Buffer },
): { signature: string; sigBody: Uint8Array } {
  const sigBody = buildPairApprovalSigBody(args);
  const pkcs8 = rawSeedToPkcs8(args.agentEd25519Priv);
  const signature = sign(null, sigBody, {
    key: pkcs8,
    format: "der",
    type: "pkcs8",
  });
  return { signature: signature.toString("base64"), sigBody };
}

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
