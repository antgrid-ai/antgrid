import { createHmac, timingSafeEqual } from "node:crypto";

/** HMAC-SHA256(secret, value) returned as a Uint8Array<ArrayBuffer> — the strict
 *  shape Prisma expects for Bytes columns in this project: never `Buffer`,
 *  always `new Uint8Array(new ArrayBuffer(n))`. */
export function hmacBytes(secret: string, value: string): Uint8Array<ArrayBuffer> {
  const digest = createHmac("sha256", secret).update(value).digest();
  const out = new Uint8Array(new ArrayBuffer(digest.length));
  out.set(digest);
  return out;
}

/** Constant-time check that `presented` hashes to `stored` under `secret`. */
export function hmacMatches(stored: Uint8Array, presented: string, secret: string): boolean {
  const computed = hmacBytes(secret, presented);
  if (stored.length !== computed.length) return false;
  return timingSafeEqual(stored, computed);
}
