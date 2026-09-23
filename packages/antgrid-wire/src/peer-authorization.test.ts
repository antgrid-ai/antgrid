import { expect, test } from "bun:test";
import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import { DecimalGenerationSchema, endpointChallengeBytes, type EndpointChallenge } from "./peer-authorization";

const challenge: EndpointChallenge = {
  challengeId: "00000000-0000-4000-8000-000000000001",
  challenge: Buffer.alloc(32).toString("base64"), accountId: "account",
  deviceId: "00000000-0000-4000-8000-000000000002", enrollmentId: "credential",
  endpointId: "01".repeat(32), expectedGeneration: "9007199254740993",
};

test("generations preserve values beyond JSON integer precision", () => {
  expect(DecimalGenerationSchema.parse(challenge.expectedGeneration)).toBe("9007199254740993");
  for (const value of [1, "01", "-1", "1e2", "9223372036854775808"]) {
    expect(DecimalGenerationSchema.safeParse(value).success).toBe(false);
  }
});

test("registration transcript binds every field and identifier boundary", () => {
  const encoded = Buffer.from(endpointChallengeBytes(challenge));
  expect(encoded.readUInt32BE(0)).toBe(Buffer.byteLength("antgrid/endpoint-registration/1"));
  for (const field of ["accountId", "enrollmentId"] as const) {
    expect(Buffer.from(endpointChallengeBytes({ ...challenge, [field]: `${challenge[field]}x` })).equals(encoded)).toBe(false);
  }
  expect(Buffer.from(endpointChallengeBytes({ ...challenge, accountId: "a", enrollmentId: "bc" }))
    .equals(Buffer.from(endpointChallengeBytes({ ...challenge, accountId: "ab", enrollmentId: "c" })))).toBe(false);
});

test("cross-language enrollment vector binds both Ed25519 identities", () => {
  const fixture = JSON.parse(readFileSync(new URL("../../../evals/fixtures/endpoint-registration-vectors.json", import.meta.url), "utf8"));
  const bytes = endpointChallengeBytes(fixture.challenge);
  expect(Buffer.from(bytes).toString("hex")).toBe(fixture.transcriptHex);
  for (const [publicBytes, signature] of [
    [Buffer.from(fixture.devicePublic, "base64"), fixture.deviceSignature],
    [Buffer.from(fixture.challenge.endpointId, "hex"), fixture.endpointSignature],
  ] as const) {
    const publicKey = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), publicBytes]), type: "spki", format: "der" });
    expect(verify(null, bytes, publicKey, Buffer.from(signature, "base64"))).toBe(true);
    const changed = endpointChallengeBytes({ ...fixture.challenge, accountId: "other" });
    expect(verify(null, changed, publicKey, Buffer.from(signature, "base64"))).toBe(false);
  }
});
