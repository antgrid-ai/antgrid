import { createCipheriv, hkdfSync, randomBytes } from "node:crypto";
import { generateEphemeralKeypair, deriveSharedSecret } from "../key-exchange";

const PUSH_HKDF_INFO = "antgrid-push-v1";
const NONCE_LEN = 12;

export interface PushBlob {
  epk: string; // base64 ephemeral X25519 public key
  box: string; // base64 of nonce(12) ‖ ciphertext ‖ tag(16)
}

/**
 * Seal `payloadJson` to the phone's persistent push public key using an
 * ephemeral-static X25519 sealed box + AES-256-GCM. The recipient derives the
 * same key from (its static private key, epk). Keep the KDF in lockstep with
 * packages/antgrid_relay_client/lib/src/e2e/push_open.dart and the wire schema
 * in packages/antgrid-wire/src/push-protocol.ts.
 */
export function sealPush(payloadJson: string, recipientPushPubkeyB64: string): PushBlob {
  const eph = generateEphemeralKeypair();
  const recipientPub = Buffer.from(recipientPushPubkeyB64, "base64");
  const shared = deriveSharedSecret(eph.privateKey, recipientPub);
  eph.privateKey.fill(0); // ephemeral key served its purpose; don't leave it in memory
  // Bind the derived key to the ephemeral public key via the HKDF salt.
  const key = Buffer.from(hkdfSync("sha256", shared, eph.publicKey, PUSH_HKDF_INFO, 32));
  shared.fill(0);
  const nonce = randomBytes(NONCE_LEN);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  const ct = Buffer.concat([cipher.update(payloadJson, "utf8"), cipher.final()]);
  const box = Buffer.concat([nonce, ct, cipher.getAuthTag()]);
  key.fill(0);
  return { epk: eph.publicKey.toString("base64"), box: box.toString("base64") };
}
