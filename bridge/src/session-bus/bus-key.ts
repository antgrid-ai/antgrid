import { createPublicKey } from "node:crypto";
import { x25519PrivateKeyFromRaw, x25519RawPublicKey } from "../key-exchange";

export interface BusKeyPair {
  /** Raw 32-byte X25519 public key, base64. */
  publicKey: string;
  /** Raw 32-byte X25519 private key, base64. */
  privateKey: string;
}

/** Returns the pair only when the halves belong together: an unrelated 32-byte
 *  public value would be registered with the directory and nothing could ever
 *  open a message sealed to it. Any malformed input yields null. */
export function loadBusKey(pub?: string, priv?: string): BusKeyPair | null {
  if (!pub || !priv) return null;
  try {
    const pubRaw = Buffer.from(pub, "base64");
    const privRaw = Buffer.from(priv, "base64");
    if (pubRaw.length !== 32 || privRaw.length !== 32) return null;
    const derived = x25519RawPublicKey(createPublicKey(x25519PrivateKeyFromRaw(privRaw)));
    if (!derived.equals(pubRaw)) return null;
    return { publicKey: pubRaw.toString("base64"), privateKey: privRaw.toString("base64") };
  } catch {
    return null;
  }
}
