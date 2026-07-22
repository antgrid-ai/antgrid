// bridge/tests/e2e/confirm.test.ts
import { describe, expect, test } from "bun:test";
import { agentConfirmTag, phoneConfirmTag, verifyConfirmTag } from "../../src/e2e/confirm";

describe("confirm tags", () => {
  const k = Buffer.alloc(32, 3);

  test("agent and phone tags differ, are 32 bytes, deterministic", () => {
    const a = agentConfirmTag(k);
    const p = phoneConfirmTag(k);
    expect(a.length).toBe(32);
    expect(p.length).toBe(32);
    expect(a.equals(p)).toBe(false);
    expect(agentConfirmTag(k).equals(a)).toBe(true);
  });

  test("verifyConfirmTag: accepts exact, rejects tamper and wrong length", () => {
    const a = agentConfirmTag(k);
    expect(verifyConfirmTag(a, agentConfirmTag(k))).toBe(true);
    const bad = Buffer.from(a);
    bad[0] ^= 1;
    expect(verifyConfirmTag(a, bad)).toBe(false);
    expect(verifyConfirmTag(a, a.subarray(0, 31))).toBe(false);
  });
});
