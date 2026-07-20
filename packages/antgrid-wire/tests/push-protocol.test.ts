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

  it("rejects a non-fcm provider", () => {
    const bad = { type: "push:deliver", pushToken: "t", provider: "apns", blob: { epk: "a", box: "b" } };
    expect(PushDeliverMessage.safeParse(bad).success).toBe(false);
  });

  it("rejects a missing blob field", () => {
    const bad = { type: "push:deliver", pushToken: "t", provider: "fcm", blob: { epk: "a" } };
    expect(PushDeliverMessage.safeParse(bad).success).toBe(false);
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
