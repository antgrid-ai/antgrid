import { expect, test } from "bun:test";
import { createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import { DecimalGenerationSchema, endpointChallengeBytes, PeerRelayAdmissionRequestSchema, PeerRelayAdmissionResponseSchema, type EndpointChallenge } from "./peer-authorization";

const challenge: EndpointChallenge = {
  challengeId: "00000000-0000-4000-8000-000000000001",
  challenge: Buffer.alloc(32).toString("base64"), accountId: "account",
  deviceId: "00000000-0000-4000-8000-000000000002", enrollmentId: "credential",
  endpointId: "01".repeat(32), expectedGeneration: "9007199254740993",
};

test("relay admission rejects unapproved URL shapes and unbounded leases", () => {
  const request = { endpointId: challenge.endpointId, relayUrl: "https://relay.example/", requestId: challenge.challengeId, issuedAt: 1 };
  expect(PeerRelayAdmissionRequestSchema.safeParse(request).success).toBe(true);
  for (const relayUrl of ["http://relay.example/", "https://user@relay.example/", "https://relay.example/path", "https://relay.example/?token=x"]) {
    expect(PeerRelayAdmissionRequestSchema.safeParse({ ...request, relayUrl }).success).toBe(false);
  }
  const response = { allowed: true, requestId: request.requestId, endpointId: request.endpointId,
    userId: "account", deviceId: challenge.deviceId, enrollmentId: "credential",
    registrationGeneration: "9007199254740993", policyGeneration: "1", leaseMs: 60000 };
  expect(PeerRelayAdmissionResponseSchema.safeParse(response).success).toBe(true);
  for (const leaseMs of [0, -1, 60001, 1.5]) {
    expect(PeerRelayAdmissionResponseSchema.safeParse({ ...response, leaseMs }).success).toBe(false);
  }
  expect(PeerRelayAdmissionResponseSchema.safeParse({ allowed: false }).success).toBe(false);
  expect(PeerRelayAdmissionResponseSchema.safeParse({ allowed: false, requestId: request.requestId }).success).toBe(true);
});

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
