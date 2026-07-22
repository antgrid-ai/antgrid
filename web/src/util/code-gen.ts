import { randomBytes } from "node:crypto";

// A-Z + 2-9, excluding I/L/O/U/0/1 to avoid visual confusion.
// Not strict Crockford base32 — we never decode, only match via hash.
const ALPHA = "ABCDEFGHJKMNPQRSTVWXYZ23456789";

function randomChars(n: number): string {
  let out = "";
  const buf = randomBytes(n);
  for (let i = 0; i < n; i++) out += ALPHA[buf[i] % ALPHA.length];
  return out;
}

/** Human-enterable. Format: ABCD-EFGH. */
export function generateUserCode(): string {
  return `${randomChars(4)}-${randomChars(4)}`;
}

/** Long, opaque, polled by CLI. */
export function generateDeviceCode(): string {
  return randomBytes(32).toString("base64url");
}
