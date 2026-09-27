import { createPrivateKey, createPublicKey, sign } from "node:crypto";
import { endpointChallengeBytes, type EndpointChallenge } from "../src/peer-authorization";

const key = (value: number) => createPrivateKey({
  key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), Buffer.alloc(32, value)]),
  type: "pkcs8", format: "der",
});
const publicBytes = (value: number) => createPublicKey(key(value)).export({ type: "spki", format: "der" }).subarray(-32);
const challenge: EndpointChallenge = {
  challengeId: "00000000-0000-4000-8000-000000000001",
  challenge: Buffer.alloc(32, 3).toString("base64"), accountId: "account-α",
  deviceId: "00000000-0000-4000-8000-000000000002", enrollmentId: "credential",
  endpointId: publicBytes(22).toString("hex"), expectedGeneration: "9007199254740993",
};
const bytes = endpointChallengeBytes(challenge);
await Bun.write(new URL("../../../evals/fixtures/endpoint-registration-vectors.json", import.meta.url), JSON.stringify({
  comment: "Deterministic test-only seeds. Regenerate with packages/antgrid-wire/scripts/gen-endpoint-vectors.ts.",
  challenge, transcriptHex: Buffer.from(bytes).toString("hex"),
  deviceSeed: Buffer.alloc(32, 11).toString("base64"), endpointSeed: Buffer.alloc(32, 22).toString("base64"),
  devicePublic: publicBytes(11).toString("base64"),
  deviceSignature: sign(null, bytes, key(11)).toString("base64"),
  endpointSignature: sign(null, bytes, key(22)).toString("base64"),
}, null, 2) + "\n");
