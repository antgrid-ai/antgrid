import { verify } from "node:crypto";
import type { z } from "zod";
import type { PairApprovalMessage } from "./protocol";

type Approval = z.infer<typeof PairApprovalMessage>;

const DOMAIN = "antgrid.pair-approval.v1";
const NUL = Buffer.from([0]);
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export type VerifyResult =
  | { ok: true }
  | {
      ok: false;
      reason: "APPROVAL_EXPIRED" | "NONCE_MISMATCH" | "BAD_SIGNATURE";
    };

/**
 * Verify a pair-approval signature produced by the agent's Ed25519 key.
 *
 * The canonical sigBody is the raw concatenation (no SHA-256 pre-hash) —
 * Ed25519 already hashes internally with SHA-512 — and must match the
 * encoding used by `bridge/src/pair-approval.ts:buildPairApprovalSigBody`
 * byte-for-byte.
 */
export function verifyPairApproval(args: {
  agentEd25519Pubkey: string; // base64 raw 32 bytes
  agentDeviceId: string;
  approval: Approval;
  expectedNonce: string;
}): VerifyResult {
  if (args.approval.nonce !== args.expectedNonce) {
    return { ok: false, reason: "NONCE_MISMATCH" };
  }
  const exp = Date.parse(args.approval.expiresAt);
  if (!Number.isFinite(exp) || exp < Date.now()) {
    return { ok: false, reason: "APPROVAL_EXPIRED" };
  }

  const sigBody = Buffer.concat([
    Buffer.from(DOMAIN, "utf8"),
    NUL,
    Buffer.from(args.agentDeviceId, "utf8"),
    NUL,
    Buffer.from(args.approval.phonePubkey, "base64"),
    NUL,
    Buffer.from(args.approval.phoneDeviceId, "utf8"),
    NUL,
    Buffer.from(args.approval.nonce, "base64"),
    NUL,
    Buffer.from(args.approval.expiresAt, "utf8"),
  ]);

  const pubRaw = Buffer.from(args.agentEd25519Pubkey, "base64");
  if (pubRaw.length !== 32) return { ok: false, reason: "BAD_SIGNATURE" };
  const spki = Buffer.concat([ED25519_SPKI_PREFIX, pubRaw]);

  let ok = false;
  try {
    ok = verify(
      null,
      sigBody,
      { key: spki, format: "der", type: "spki" },
      Buffer.from(args.approval.signature, "base64"),
    );
  } catch {
    ok = false;
  }
  return ok ? { ok: true } : { ok: false, reason: "BAD_SIGNATURE" };
}
