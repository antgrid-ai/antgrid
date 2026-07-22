import { verify } from "node:crypto";

import { ED25519_SPKI_PREFIX, NUL } from "./ed25519-der";

/**
 * Inputs to the pair-request signature.
 *
 * Encoding contract: `phonePubkey` and `nonce` are standard base64 (RFC
 * 4648 §4, padded); `requestedAt` is ISO-8601 with a `Z` suffix. The
 * returned sigBody is the raw canonical bytes — Ed25519 hashes it
 * internally with SHA-512, no pre-hash. The Dart sign side
 * (`packages/antgrid_relay_client/lib/src/pair_sign.dart`) must produce
 * byte-for-byte identical bytes.
 */
export interface PairRequestArgs {
  agentDeviceId: string;
  phonePubkey: string; // base64
  phoneDeviceId: string;
  nonce: string; // base64
  requestedAt: string; // ISO-8601
}

const DOMAIN = "antgrid.pair-request.v1";

/**
 * Canonical sigBody layout:
 *   "antgrid.pair-request.v1" || 0x00 ||
 *   agentDeviceId (utf8)    || 0x00 ||
 *   base64Decode(phonePubkey) || 0x00 ||
 *   phoneDeviceId (utf8)    || 0x00 ||
 *   base64Decode(nonce)     || 0x00 ||
 *   requestedAt (utf8 ISO-8601, no trailing 0x00)
 *
 * The domain prefix separates pair-request signatures from
 * `antgrid.pair-approval.v1` so neither key can produce a signature valid in
 * the other role.
 */
export function buildPairRequestSigBody(args: PairRequestArgs): Uint8Array {
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
    Buffer.from(args.requestedAt, "utf8"),
  ]);
}

export type VerifyResult =
  | { ok: true }
  | { ok: false; reason: "BAD_SIGNATURE" | "STALE_REQUEST" };

const MAX_AGE_MS = 30_000;
const MAX_FUTURE_SKEW_MS = 5_000;

/**
 * Verify a phone-signed pair-request. Returns:
 *   - {ok: true}                  on success
 *   - {ok: false, reason: "STALE_REQUEST"}  if requestedAt is unparseable or
 *     outside the window [now - 30 s, now + 5 s]
 *   - {ok: false, reason: "BAD_SIGNATURE"}  on any other failure (key length,
 *     decode error, signature mismatch)
 */
export function verifyPairRequest(args: {
  phonePubkey: string;
  agentDeviceId: string;
  phoneDeviceId: string;
  nonce: string;
  requestedAt: string;
  phoneSignature: string;
  now?: number; // injectable for tests
}): VerifyResult {
  const nowMs = args.now ?? Date.now();
  const at = Date.parse(args.requestedAt);
  if (!Number.isFinite(at)) {
    return { ok: false, reason: "STALE_REQUEST" };
  }
  const skew = nowMs - at;
  if (skew > MAX_AGE_MS || skew < -MAX_FUTURE_SKEW_MS) {
    return { ok: false, reason: "STALE_REQUEST" };
  }

  let pubRaw: Buffer;
  try {
    pubRaw = Buffer.from(args.phonePubkey, "base64");
  } catch {
    return { ok: false, reason: "BAD_SIGNATURE" };
  }
  if (pubRaw.length !== 32) return { ok: false, reason: "BAD_SIGNATURE" };
  const spki = Buffer.concat([ED25519_SPKI_PREFIX, pubRaw]);

  const sigBody = buildPairRequestSigBody({
    agentDeviceId: args.agentDeviceId,
    phonePubkey: args.phonePubkey,
    phoneDeviceId: args.phoneDeviceId,
    nonce: args.nonce,
    requestedAt: args.requestedAt,
  });

  let ok = false;
  try {
    ok = verify(
      null,
      sigBody,
      { key: spki, format: "der", type: "spki" },
      Buffer.from(args.phoneSignature, "base64"),
    );
  } catch {
    ok = false;
  }
  return ok ? { ok: true } : { ok: false, reason: "BAD_SIGNATURE" };
}
