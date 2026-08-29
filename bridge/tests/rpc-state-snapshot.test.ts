import { describe, expect, test } from "bun:test";
import { z } from "zod";
import { MessageBus } from "../src/message-bus";
import { createMessage, type RpcRequest, type RpcResponse } from "../src/protocol";
import { dispatchRpc, _registerMethodForTest } from "../src/rpc/methods";
import { snapshotAsksFor } from "../src/rpc/state-snapshot";

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

  // The app pulls its durable state in two round trips split by weight: the
  // status/git frames the terminal is built from, then every checkout's file
  // tree on its own. `exclude` is what keeps the tree out of the first.
  test("a ['*'] pull with exclude leaves the excluded types out", async () => {
    const bus = new MessageBus();
    bus.publish(createMessage("tree:full", {
      projectId: "p1",
      root: { name: "root", path: "/", type: "directory" as const, children: [] },
    }), "control");
    bus.publish(createMessage("git:status", { projectId: "p1", files: [] }), "control");

    const res = (await dispatchRpc(bus, createMessage("request", {
      requestId: "r1",
      method: "state.snapshot",
      params: { types: ["*"], exclude: ["tree:full"] },
    }))) as RpcResponse;
    expect(res.ok).toBe(true);
    expect((res.result as { frames: any[] }).frames.map((f) => f.type)).toEqual(["git:status"]);
  });

  test("snapshotAsksFor reads a pull the way getSnapshot answers it", () => {
    expect(snapshotAsksFor({ types: ["*"] }, ["agent:status"])).toBe(true);
    expect(snapshotAsksFor({ types: ["*"], exclude: ["tree:full"] }, ["agent:status"])).toBe(true);
    expect(snapshotAsksFor({ types: ["*"], exclude: ["agent:status"] }, ["agent:status"])).toBe(false);
    expect(snapshotAsksFor({ types: ["tree:full"] }, ["agent:status"])).toBe(false);
    expect(snapshotAsksFor({ types: ["agent:tools"] }, ["agent:projects", "agent:tools"])).toBe(true);
    // Malformed: the recompute is harmless and dispatchRpc rejects the request.
    expect(snapshotAsksFor({ types: "nope" }, ["agent:status"])).toBe(true);
    expect(snapshotAsksFor(undefined, ["agent:status"])).toBe(true);
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
