// bridge/src/e2e/confirm.ts
// Spec: docs/protocol/e2e-handshake.md §"Key confirmation".
import { createHmac, timingSafeEqual } from "node:crypto";

const AGENT_LABEL = "agent-finished";
const PHONE_LABEL = "phone-finished";

export function agentConfirmTag(confirmKey: Buffer): Buffer {
  return createHmac("sha256", confirmKey).update(AGENT_LABEL).digest();
}

export function phoneConfirmTag(confirmKey: Buffer): Buffer {
  return createHmac("sha256", confirmKey).update(PHONE_LABEL).digest();
}

/** Constant-time comparison; false on any length mismatch. */
export function verifyConfirmTag(expected: Buffer, presented: Buffer): boolean {
  if (expected.length !== presented.length) return false;
  return timingSafeEqual(expected, presented);
}
