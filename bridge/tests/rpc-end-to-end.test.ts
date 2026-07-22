import { describe, expect, test } from "bun:test";
import { MessageBus } from "../src/message-bus";
import { createMessage, type RpcResponse, type AbMessage } from "../src/protocol";
import { dispatchRpc } from "../src/rpc/methods";

describe("rpc end-to-end via MessageBus", () => {
  test("inbound request triggers a response on the bus", async () => {
    const bus = new MessageBus();
    const sent: AbMessage[] = [];
    bus.subscribe({ deliver: (m) => sent.push(m) });

    const tree = createMessage("tree:full", {
      projectId: "p1",
      root: { name: "root", path: "/", type: "directory" as const, children: [] },
    });
    bus.publish(tree, "control");

    // Simulate the index.ts wiring directly.
    bus.setInboundHandler(async (msg, channel) => {
      if (msg.type === "request") {
        const res = await dispatchRpc(bus, msg);
        bus.publish(res, channel);
      }
    });

    const req = createMessage("request", {
      requestId: "r1",
      method: "state.snapshot",
      params: { types: ["tree:full"] },
    });
    bus.dispatchInbound(req, "control");

    await new Promise((r) => setTimeout(r, 10));

    const response = sent.find((m) => m.type === "response") as RpcResponse | undefined;
    expect(response).toBeDefined();
    expect(response!.ok).toBe(true);
    const result = response!.result as { frames: any[] };
    expect(result.frames[0].type).toBe("tree:full");
  });
});
