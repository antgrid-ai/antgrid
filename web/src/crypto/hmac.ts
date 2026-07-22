import { hmac } from "@noble/hashes/hmac";
import { sha256 } from "@noble/hashes/sha256";

export function hmacSha256(key: Uint8Array, message: Uint8Array): Uint8Array {
  return hmac(sha256, key, message);
}

export function toBase64Url(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("base64url");
}
