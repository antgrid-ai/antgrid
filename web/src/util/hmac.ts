import { Buffer } from "node:buffer";
import { createHmac, timingSafeEqual } from "node:crypto";

/** HMAC-SHA256(secret, value) returned as a Uint8Array<ArrayBuffer> — the strict
 *  shape Prisma expects for Bytes columns in this project: never `Buffer`,
 *  always `new Uint8Array(new ArrayBuffer(n))`. */
export function hmacBytes(secret: string, value: string | Uint8Array): Uint8Array<ArrayBuffer> {
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

const HEX = /^[0-9a-fA-F]+$/;

/**
 * Constant-time check of a hex signature digest — the shape a provider sends in
 * a header (`sha256=<hex>`) over the raw request bytes.
 *
 * Returns false rather than throwing for a digest of the wrong length or with
 * non-hex characters. `timingSafeEqual` on unequal-length buffers *throws*, so a
 * bare compare would turn an attacker-controlled header length into a 500; and
 * `Buffer.from(hex, "hex")` silently truncates at the first non-hex character,
 * which is why the charset is checked rather than assumed.
 */
export function hmacHexMatches(
  secret: string,
  value: string | Uint8Array,
  presentedHex: string
): boolean {
  const expected = hmacBytes(secret, value);
  if (presentedHex.length !== expected.length * 2 || !HEX.test(presentedHex)) return false;
  const decoded = Buffer.from(presentedHex, "hex");
  const presented = new Uint8Array(new ArrayBuffer(decoded.length));
  presented.set(decoded);
  return timingSafeEqual(presented, expected);
}
