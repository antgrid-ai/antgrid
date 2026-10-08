import { describe, it, expect } from "bun:test";
import { ClientMessage, ServerMessage, PushDeliverMessage, PushResultMessage } from "../src/index";

describe("push:deliver", () => {
  it("parses a valid push:deliver", () => {
    const msg = {
      type: "push:deliver",
      pushToken: "fcm-token-abc",
      provider: "fcm",
      blob: { epk: "ZXBr", box: "Ym94" },
    };
    const parsed = PushDeliverMessage.parse(msg);
    expect(parsed.blob.epk).toBe("ZXBr");
    // Also reachable through the ClientMessage union:
    const viaUnion = ClientMessage.parse(msg);
    expect(viaUnion.type).toBe("push:deliver");
  });

  it("parses an apns push:deliver through the union", () => {
    const msg = { type: "push:deliver", pushToken: "apns-hex-token", provider: "apns", blob: { epk: "ZXBr", box: "Ym94" } };
    expect(PushDeliverMessage.parse(msg).provider).toBe("apns");
    expect(ClientMessage.parse(msg).type).toBe("push:deliver");
  });

  it("rejects an unknown provider", () => {
    const bad = { type: "push:deliver", pushToken: "t", provider: "gcm", blob: { epk: "a", box: "b" } };
    expect(PushDeliverMessage.safeParse(bad).success).toBe(false);
  });

  it("rejects a missing blob field", () => {
    const bad = { type: "push:deliver", pushToken: "t", provider: "fcm", blob: { epk: "a" } };
    expect(PushDeliverMessage.safeParse(bad).success).toBe(false);
  });

  const base = { type: "push:deliver", pushToken: "t", provider: "fcm", blob: { epk: "a", box: "b" } } as const;

  it("accepts an absent collapseKey", () => {
    expect(PushDeliverMessage.parse(base).collapseKey).toBeUndefined();
  });

  it("accepts a base64url collapseKey up to 64 chars", () => {
    for (const key of ["a", "Ab3_-xY9Ab3_-xY9Ab3_-xY9Ab3_-xY9", "k".repeat(64)]) {
      expect(PushDeliverMessage.parse({ ...base, collapseKey: key }).collapseKey).toBe(key);
      expect(ClientMessage.parse({ ...base, collapseKey: key })).toMatchObject({ collapseKey: key });
    }
  });

  it("rejects a collapseKey outside the base64url alphabet or over 64 chars", () => {
    for (const key of ["", "a/b", "a+b", "ab==", "a b", "k".repeat(65)]) {
      expect(PushDeliverMessage.safeParse({ ...base, collapseKey: key }).success).toBe(false);
    }
  });
});

describe("push:result", () => {
  it("parses an ok result with no reason (and via the ServerMessage union)", () => {
    const msg = { type: "push:result", pushToken: "tok", ok: true };
    expect(PushResultMessage.parse(msg).ok).toBe(true);
    expect(ServerMessage.parse(msg).type).toBe("push:result");
  });

  it("parses a failure result with a reason", () => {
    const msg = { type: "push:result", pushToken: "tok", ok: false, reason: "unregistered" };
    const parsed = PushResultMessage.parse(msg);
    expect(parsed.ok).toBe(false);
    expect(parsed.reason).toBe("unregistered");
  });
});
