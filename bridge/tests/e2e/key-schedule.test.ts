// bridge/tests/e2e/key-schedule.test.ts
import { describe, expect, test } from "bun:test";
import { deriveSessionKeys } from "../../src/e2e/key-schedule";
import { buildTranscript } from "../../src/e2e/transcript";

function fullTranscript() {
  return buildTranscript({
    registrationId: "agent-dev.proj1",
    role: "agent",
    agentDeviceId: "agent-dev.proj1",
    phoneDeviceId: "phone-1",
    agentX25519Pub: Buffer.alloc(32, 5),
    phoneX25519Pub: Buffer.alloc(32, 7),
    nonce: Buffer.alloc(32, 9),
  });
}

describe("deriveSessionKeys", () => {
  test("returns three distinct 32-byte keys, deterministic", () => {
    const k1 = deriveSessionKeys(Buffer.alloc(32, 1), fullTranscript());
    const k2 = deriveSessionKeys(Buffer.alloc(32, 1), fullTranscript());
    for (const k of [k1.a2p, k1.p2a, k1.confirm]) expect(k.length).toBe(32);
    expect(k1.a2p.equals(k2.a2p)).toBe(true);
    expect(k1.p2a.equals(k2.p2a)).toBe(true);
    expect(k1.confirm.equals(k2.confirm)).toBe(true);
    expect(k1.a2p.equals(k1.p2a)).toBe(false);
    expect(k1.a2p.equals(k1.confirm)).toBe(false);
    k1.a2p.fill(0);
    expect(k1.p2a.equals(k2.p2a)).toBe(true); // p2a unaffected by a2p zeroization
    expect(k1.confirm.equals(k2.confirm)).toBe(true);
  });

  test("zeroizes the shared secret", () => {
    const ss = Buffer.alloc(32, 1);
    deriveSessionKeys(ss, fullTranscript());
    expect(ss.equals(Buffer.alloc(32, 0))).toBe(true);
  });

  test("different transcript context yields different keys", () => {
    const a = deriveSessionKeys(Buffer.alloc(32, 1), fullTranscript());
    const other = buildTranscript({
      registrationId: "agent-dev.proj2", // changed
      role: "agent",
      agentDeviceId: "agent-dev.proj2",
      phoneDeviceId: "phone-1",
      agentX25519Pub: Buffer.alloc(32, 5),
      phoneX25519Pub: Buffer.alloc(32, 7),
      nonce: Buffer.alloc(32, 9),
    });
    const b = deriveSessionKeys(Buffer.alloc(32, 1), other);
    expect(a.a2p.equals(b.a2p)).toBe(false);
  });
});
