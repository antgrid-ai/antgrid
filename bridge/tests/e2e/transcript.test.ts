// bridge/tests/e2e/transcript.test.ts
import { describe, expect, test } from "bun:test";
import { buildTranscript, DOMAIN_V2, VERSION_BYTE } from "../../src/e2e/transcript";

const base = {
  registrationId: "agent-dev.proj1",
  role: "phone" as const,
  agentDeviceId: "agent-dev.proj1",
  phoneDeviceId: "phone-1",
  agentX25519Pub: Buffer.alloc(0), // empty in sig_p
  phoneX25519Pub: Buffer.alloc(32, 7),
  nonce: Buffer.alloc(32, 9),
};

describe("buildTranscript v2", () => {
  test("layout: domain, version byte, fields, 0x00 separators, no trailing", () => {
    const t = buildTranscript(base);
    const expected = Buffer.concat([
      Buffer.from(DOMAIN_V2, "utf8"), Buffer.from([0]),
      Buffer.from([VERSION_BYTE]), Buffer.from([0]),
      Buffer.from("agent-dev.proj1", "utf8"), Buffer.from([0]),
      Buffer.from("phone", "utf8"), Buffer.from([0]),
      Buffer.from("agent-dev.proj1", "utf8"), Buffer.from([0]),
      Buffer.from("phone-1", "utf8"), Buffer.from([0]),
      /* agent pub empty */ Buffer.from([0]),
      Buffer.alloc(32, 7), Buffer.from([0]),
      Buffer.alloc(32, 9),
    ]);
    expect(t.equals(expected)).toBe(true);
  });

  test("different registrationId changes bytes (channel binding)", () => {
    const a = buildTranscript(base);
    const b = buildTranscript({ ...base, registrationId: "agent-dev.proj2" });
    expect(a.equals(b)).toBe(false);
  });

  test("role agent with full agent pub", () => {
    const t = buildTranscript({ ...base, role: "agent", agentX25519Pub: Buffer.alloc(32, 5) });
    expect(t.includes(Buffer.alloc(32, 5))).toBe(true);
  });
});
