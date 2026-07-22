// bridge/tests/e2e/handshake-sig.test.ts
import { describe, expect, test } from "bun:test";
import { generateKeyPairSync } from "node:crypto";
import { signTranscript, verifyTranscriptSig } from "../../src/e2e/handshake-sig";
import { buildTranscript, type TranscriptFields } from "../../src/e2e/transcript";

function ed25519Fixture(): { seed: Buffer; pubB64: string } {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const pubDer = publicKey.export({ type: "spki", format: "der" });
  const privDer = privateKey.export({ type: "pkcs8", format: "der" });
  return {
    seed: Buffer.from(privDer.subarray(privDer.length - 32)),
    pubB64: Buffer.from(pubDer.subarray(pubDer.length - 32)).toString("base64"),
  };
}

const fields: TranscriptFields = {
  registrationId: "agent-dev.proj1",
  role: "agent",
  agentDeviceId: "agent-dev.proj1",
  phoneDeviceId: "phone-1",
  agentX25519Pub: Buffer.alloc(32, 5),
  phoneX25519Pub: Buffer.alloc(32, 7),
  nonce: Buffer.alloc(32, 9),
};

describe("v2 transcript signatures", () => {
  test("sign/verify round-trip", () => {
    const { seed, pubB64 } = ed25519Fixture();
    const sigB64 = signTranscript(buildTranscript(fields), seed);
    expect(verifyTranscriptSig(buildTranscript(fields), pubB64, sigB64)).toBe(true);
  });

  test("rejects: tampered field, wrong key, malformed pub", () => {
    const { seed, pubB64 } = ed25519Fixture();
    const other = ed25519Fixture();
    const sigB64 = signTranscript(buildTranscript(fields), seed);
    const tampered = buildTranscript({ ...fields, registrationId: "agent-dev.proj2" });
    expect(verifyTranscriptSig(tampered, pubB64, sigB64)).toBe(false);
    expect(verifyTranscriptSig(buildTranscript(fields), other.pubB64, sigB64)).toBe(false);
    expect(verifyTranscriptSig(buildTranscript(fields), "AAAA", sigB64)).toBe(false);
  });
});
