import { writeFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { generateEphemeralKeypair } from "../src/key-exchange";
import { sealPush } from "../src/push/seal";

// Recipient = the phone's persistent push keypair (its raw 32-byte X25519 private
// key doubles as the Dart X25519 seed — both clamp per RFC 7748, so the same seed
// yields the same key on both sides). Node produces the blob; Dart must open it.
const recipient = generateEphemeralKeypair();
const plaintext = JSON.stringify({
  title: "Task complete", body: "done", kind: "agent", sourceMessageId: "vector-1",
});
const { epk, box } = sealPush(plaintext, recipient.publicKey.toString("base64"));
const vector = {
  recipientPrivSeed: recipient.privateKey.toString("base64"),
  recipientPub: recipient.publicKey.toString("base64"),
  epk,
  box,
  plaintext,
};
const outPath = "packages/antgrid_relay_client/test/fixtures/push_vector.json";
mkdirSync(dirname(outPath), { recursive: true });
writeFileSync(outPath, JSON.stringify(vector, null, 2) + "\n");
console.log("wrote", outPath);
