// bridge/src/e2e/key-schedule.ts
// Spec: docs/protocol/e2e-handshake.md §"Key schedule".
import { createHash, hkdfSync } from "node:crypto";

export const HKDF_INFO_V2 = "antgrid-e2e-v2";

export interface SessionKeys {
  /** agent → phone AES-256-GCM key */
  a2p: Buffer;
  /** phone → agent AES-256-GCM key */
  p2a: Buffer;
  /** key-confirmation HMAC key — never used for transport */
  confirm: Buffer;
}

/**
 * okm(96) = HKDF-SHA256(salt = SHA-256(full agent-role transcript), ikm = ss,
 * info = "antgrid-e2e-v2"). Zeroizes `sharedSecret` in place.
 */
export function deriveSessionKeys(sharedSecret: Buffer, fullAgentRoleTranscript: Buffer): SessionKeys {
  const context = createHash("sha256").update(fullAgentRoleTranscript).digest();
  const okm = Buffer.from(hkdfSync("sha256", sharedSecret, context, HKDF_INFO_V2, 96));
  sharedSecret.fill(0);
  const keys = {
    a2p: Buffer.from(okm.subarray(0, 32)),
    p2a: Buffer.from(okm.subarray(32, 64)),
    confirm: Buffer.from(okm.subarray(64, 96)),
  };
  okm.fill(0);
  return keys;
}

/** Best-effort zeroization at session teardown (spec §"Key lifetime"). */
export function zeroizeSessionKeys(keys: SessionKeys): void {
  keys.a2p.fill(0);
  keys.p2a.fill(0);
  keys.confirm.fill(0);
}
