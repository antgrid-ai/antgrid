import { describe, it, expect } from "bun:test";
import { createMessage, parseMessage } from "../src/protocol";

describe("agent:usage itemId", () => {
  it("round-trips an itemId-stamped usage frame through parseMessage", () => {
    const msg = createMessage("agent:usage", {
      sessionId: "s1",
      itemId: "msg:abc",
      total: {},
      last: { totalTokens: 1234, inputTokens: 1000, outputTokens: 234 },
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed?.type).toBe("agent:usage");
    expect(parsed?.itemId).toBe("msg:abc");
    expect(parsed?.last?.totalTokens).toBe(1234);
  });

  it("still validates without itemId (live-frame shape)", () => {
    const msg = createMessage("agent:usage", {
      sessionId: "s1",
      turnId: "t1",
      total: { totalTokens: 10 },
    });
    const parsed = parseMessage(JSON.stringify(msg)) as any;
    expect(parsed?.type).toBe("agent:usage");
    expect(parsed?.itemId).toBeUndefined();
  });
});
