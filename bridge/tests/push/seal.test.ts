import { test, expect } from "bun:test";
import { createCipheriv, createDecipheriv, hkdfSync } from "node:crypto";
import { generateEphemeralKeypair, deriveSharedSecret } from "../../src/key-exchange";
import { sealPush } from "../../src/push/seal";

test("sealPush round-trips with the recipient private key", () => {
  // Recipient (phone) persistent push keypair:
  const recipient = generateEphemeralKeypair();
  const plaintext = JSON.stringify({ title: "Task complete", body: "done", kind: "agent", sourceMessageId: "id-1" });

  const { epk, box } = sealPush(plaintext, recipient.publicKey.toString("base64"));

  // Recipient-side open (mirrors what the Dart app will do):
  const epkBuf = Buffer.from(epk, "base64");
  const secret = deriveSharedSecret(recipient.privateKey, epkBuf);
  const key = Buffer.from(hkdfSync("sha256", secret, epkBuf, "antgrid-push-v1", 32));
  const raw = Buffer.from(box, "base64");
  const nonce = raw.subarray(0, 12);
  const tag = raw.subarray(raw.length - 16);
  const ct = raw.subarray(12, raw.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAuthTag(tag);
  const opened = Buffer.concat([decipher.update(ct), decipher.final()]).toString("utf8");

  expect(opened).toBe(plaintext);
});

test("a tampered box fails to open", () => {
  const recipient = generateEphemeralKeypair();
  const { epk, box } = sealPush("secret", recipient.publicKey.toString("base64"));
  const raw = Buffer.from(box, "base64");
  raw[raw.length - 1] ^= 0xff; // flip a tag byte
  const epkBuf = Buffer.from(epk, "base64");
  const secret = deriveSharedSecret(recipient.privateKey, epkBuf);
  const key = Buffer.from(hkdfSync("sha256", secret, epkBuf, "antgrid-push-v1", 32));
  const decipher = createDecipheriv("aes-256-gcm", key, raw.subarray(0, 12));
  decipher.setAuthTag(raw.subarray(raw.length - 16));
  expect(() => Buffer.concat([decipher.update(raw.subarray(12, raw.length - 16)), decipher.final()])).toThrow();
});
