import { describe, expect, test } from "bun:test";
import { createMessage, parseMessage, parseMessageFast, type RpcRequest, type RpcResponse } from "../src/protocol";

describe("protocol: request/response", () => {
  test("parses a well-formed request", () => {
    const m = createMessage("request", { requestId: "r1", method: "state.snapshot", params: { types: ["*"] } });
    const parsed = parseMessage(JSON.stringify(m)) as RpcRequest;
    expect(parsed).not.toBeNull();
    expect(parsed.type).toBe("request");
    expect(parsed.requestId).toBe("r1");
    expect(parsed.method).toBe("state.snapshot");
    const fast = parseMessageFast(JSON.stringify(m)) as RpcRequest;
    expect(fast?.type).toBe("request");
  });

  test("parses a well-formed response", () => {
    const m = createMessage("response", { requestId: "r1", ok: true, result: { frames: [] } });
    const parsed = parseMessage(JSON.stringify(m)) as RpcResponse;
    expect(parsed.type).toBe("response");
    expect(parsed.ok).toBe(true);
    const fast = parseMessageFast(JSON.stringify(m)) as RpcResponse;
    expect(fast?.type).toBe("response");
  });

  test("parses an error response", () => {
    const m = createMessage("response", { requestId: "r1", ok: false, error: { code: "E", message: "x" } });
    const parsed = parseMessage(JSON.stringify(m)) as RpcResponse;
    expect(parsed.ok).toBe(false);
    expect(parsed.error?.code).toBe("E");
  });
});
