// bridge/tests/e2e/transport.test.ts
import { describe, expect, test } from "bun:test";
import { E2eTransport } from "../../src/e2e/transport";

describe("E2eTransport directional seal/open", () => {
  const kA2p = Buffer.alloc(32, 1);
  const kP2a = Buffer.alloc(32, 2);
  // Agent sends with a2p, receives with p2a; phone is the inverse.
  const agent = new E2eTransport({ sendKey: kA2p, recvKey: kP2a });
  const phone = new E2eTransport({ sendKey: kP2a, recvKey: kA2p });

  test("round-trips in both directions", () => {
    expect(phone.open(agent.seal("from-agent"))).toBe("from-agent");
    expect(agent.open(phone.seal("from-phone"))).toBe("from-phone");
  });

  test("reflection fails: a sealed frame cannot be opened by its sender", () => {
    expect(agent.open(agent.seal("loop"))).toBeNull();
  });

  test("open returns null on truncated or tampered input", () => {
    expect(phone.open(Buffer.alloc(10))).toBeNull();
    const sealed = agent.seal("x");
    sealed[sealed.length - 1] ^= 1;
    expect(phone.open(sealed)).toBeNull();
  });

  test("fixed-nonce hook produces deterministic output (vector support)", () => {
    const nonce = Buffer.alloc(12, 4);
    const a = agent.seal("vec", nonce);
    const b = agent.seal("vec", nonce);
    expect(a.equals(b)).toBe(true);
    expect(a.subarray(0, 12).equals(nonce)).toBe(true);
  });
});
