import { describe, expect, test } from "bun:test";
import { z } from "zod";
import { MessageBus } from "../src/message-bus";
import { createMessage, type RpcRequest, type RpcResponse } from "../src/protocol";
import { dispatchRpc, _registerMethodForTest } from "../src/rpc/methods";

describe("rpc: state.snapshot", () => {
  test("returns cached frames as a response", async () => {
    const bus = new MessageBus();
    const tree = createMessage("tree:full", {
      projectId: "p1",
      root: { name: "root", path: "/", type: "directory" as const, children: [] },
    });
    bus.publish(tree, "control");

    const req: RpcRequest = createMessage("request", {
      requestId: "r1",
      method: "state.snapshot",
      params: { types: ["*"] },
    });

    const res = (await dispatchRpc(bus, req)) as RpcResponse;
    expect(res.type).toBe("response");
    expect(res.requestId).toBe("r1");
    expect(res.ok).toBe(true);
    const result = res.result as { frames: any[] };
    expect(result.frames.map((f) => f.type)).toEqual(["tree:full"]);
  });

  test("returns ok=false with E_UNKNOWN_METHOD for an unknown method", async () => {
    const bus = new MessageBus();
    const req: RpcRequest = createMessage("request", {
      requestId: "r2",
      method: "does.not.exist",
    });
    const res = (await dispatchRpc(bus, req)) as RpcResponse;
    expect(res.ok).toBe(false);
    expect(res.error?.code).toBe("E_UNKNOWN_METHOD");
  });

  test("returns ok=false with E_BAD_PARAMS for malformed state.snapshot params", async () => {
    const bus = new MessageBus();
    const req: RpcRequest = createMessage("request", {
      requestId: "r3",
      method: "state.snapshot",
      params: { types: "not-an-array" },
    });
    const res = (await dispatchRpc(bus, req)) as RpcResponse;
    expect(res.ok).toBe(false);
    expect(res.error?.code).toBe("E_BAD_PARAMS");
  });

  test("returns ok=false with E_HANDLER when the handler throws", async () => {
    const cleanup = _registerMethodForTest("test.throw", {
      paramsSchema: z.object({}).passthrough(),
      handler: () => { throw new Error("boom"); },
    });
    try {
      const bus = new MessageBus();
      const req = createMessage("request", { requestId: "r4", method: "test.throw", params: {} });
      const res = (await dispatchRpc(bus, req)) as RpcResponse;
      expect(res.ok).toBe(false);
      expect(res.error?.code).toBe("E_HANDLER");
      expect(res.error?.message).toBe("boom");
    } finally {
      cleanup();
    }
  });
});
