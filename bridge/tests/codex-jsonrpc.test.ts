import { describe, it, expect, afterEach } from "bun:test";
import { JsonRpcEndpoint } from "../src/codex/jsonrpc-stdio";

// Endpoints read from a never-closing in-memory stream; dispose them after each
// test so their read loop stops holding the stream open (an undisposed reader
// keeps Bun's event loop alive and wedges the whole run at teardown).
const live: JsonRpcEndpoint[] = [];
afterEach(() => { for (const ep of live.splice(0)) ep.dispose(); });

// Build an endpoint wired to in-memory pipes we control from the test.
function makePair() {
  const outbound: string[] = []; // lines the endpoint wrote
  let pushInbound: (line: string) => void = () => {};
  const inbound = new ReadableStream<string>({
    start(controller) {
      pushInbound = (line) => controller.enqueue(line);
    },
  });
  const ep = new JsonRpcEndpoint({
    readLines: inbound,
    writeLine: (line) => { outbound.push(line); },
  });
  live.push(ep);
  return { ep, outbound, pushInbound };
}

describe("JsonRpcEndpoint", () => {
  it("sends a request and resolves on the matching response", async () => {
    const { ep, outbound, pushInbound } = makePair();
    const p = ep.request("thread/start", { cwd: "/x" });
    // The endpoint should have written exactly one request line with an id.
    const sent = JSON.parse(outbound[0]);
    expect(sent.method).toBe("thread/start");
    expect(sent.jsonrpc).toBe("2.0");
    expect(typeof sent.id).toBe("number");
    pushInbound(JSON.stringify({ jsonrpc: "2.0", id: sent.id, result: { thread: { id: "th1" } } }));
    const result = await p;
    expect((result as any).thread.id).toBe("th1");
  });

  it("rejects a request when the response is an error", async () => {
    const { ep, outbound, pushInbound } = makePair();
    const p = ep.request("turn/start", {});
    const sent = JSON.parse(outbound[0]);
    pushInbound(JSON.stringify({ jsonrpc: "2.0", id: sent.id, error: { code: -32000, message: "boom" } }));
    await expect(p).rejects.toThrow("boom");
  });

  it("dispatches inbound notifications by method", async () => {
    const { ep, pushInbound } = makePair();
    const got: any[] = [];
    ep.onNotification("item/started", (params) => got.push(params));
    pushInbound(JSON.stringify({ jsonrpc: "2.0", method: "item/started", params: { itemId: "i1" } }));
    await Promise.resolve();
    expect(got).toEqual([{ itemId: "i1" }]);
  });

  it("answers inbound server->client requests via the registered handler", async () => {
    const { ep, outbound, pushInbound } = makePair();
    ep.onRequest("item/commandExecution/requestApproval", async () => ({ decision: "accept" }));
    pushInbound(JSON.stringify({ jsonrpc: "2.0", id: 99, method: "item/commandExecution/requestApproval", params: {} }));
    await Promise.resolve(); await Promise.resolve();
    const reply = JSON.parse(outbound[outbound.length - 1]);
    expect(reply.id).toBe(99);
    expect(reply.result.decision).toBe("accept");
  });

  it("passes the inbound rpc id to request handlers (string and number)", async () => {
    const { ep, pushInbound } = makePair();
    const seen: unknown[] = [];
    ep.onRequest("x/approve", async (_p, id) => {
      seen.push(id);
      return {};
    });
    pushInbound(JSON.stringify({ jsonrpc: "2.0", id: "req-7", method: "x/approve", params: {} }));
    pushInbound(JSON.stringify({ jsonrpc: "2.0", id: 42, method: "x/approve", params: {} }));
    // Two stream reads need more than the bare two microtask ticks the
    // single-push tests get away with; a macrotask drains everything.
    await new Promise((r) => setTimeout(r, 0));
    expect(seen).toEqual(["req-7", 42]);
  });

  it("rejects in-flight requests when the peer stream closes (codex exit)", async () => {
    let closeInbound: () => void = () => {};
    const inbound = new ReadableStream<string>({
      start(controller) { closeInbound = () => controller.close(); },
    });
    const ep = new JsonRpcEndpoint({ readLines: inbound, writeLine: () => {} });
    const p = ep.request("thread/start", {});
    closeInbound(); // codex closed stdout without replying
    await expect(p).rejects.toThrow("codex stream closed");
  });

  it("rejects in-flight requests on dispose()", async () => {
    const { ep } = makePair();
    const p = ep.request("thread/start", {});
    ep.dispose();
    await expect(p).rejects.toThrow("endpoint disposed");
  });

  it("rejects a request that is never answered once its timeout elapses", async () => {
    const { ep } = makePair();
    // A hung-but-alive peer never replies and never closes the stream.
    const p = ep.request("thread/start", {}, 20);
    await expect(p).rejects.toThrow("timed out");
  });

  it("does not fire the timeout for a request answered in time", async () => {
    const { ep, outbound, pushInbound } = makePair();
    const p = ep.request("thread/start", {}, 1000);
    const sent = JSON.parse(outbound[0]);
    pushInbound(JSON.stringify({ jsonrpc: "2.0", id: sent.id, result: { ok: true } }));
    expect((await p as any).ok).toBe(true);
  });
});
