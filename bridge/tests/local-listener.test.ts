import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { LocalListener } from "../src/local-listener";
import { MessageBus } from "../src/message-bus";
import { createMessage } from "../src/protocol";

let listener: LocalListener;
let bus: MessageBus;

beforeEach(async () => {
  bus = new MessageBus();
  listener = new LocalListener({ bus, token: "secret-token" });
  await listener.start();
});
afterEach(async () => { await listener.stop(); });

async function openWs(token = "secret-token", appPid = 12345): Promise<WebSocket> {
  const ws = new WebSocket(`ws://127.0.0.1:${listener.port}`);
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = (e) => reject(e);
  });
  ws.send(JSON.stringify({ type: "hello", token, appPid, appVersion: "test" }));
  return ws;
}

function nextMessage(ws: WebSocket): Promise<any> {
  return new Promise((resolve) => {
    ws.onmessage = (ev) => resolve(JSON.parse(String(ev.data)));
  });
}

function nextClose(ws: WebSocket): Promise<{ code: number; reason: string }> {
  return new Promise((resolve) => {
    ws.onclose = (ev) => resolve({ code: ev.code, reason: ev.reason });
  });
}

describe("LocalListener handshake", () => {
  test("valid token returns ready", async () => {
    const ws = await openWs();
    const msg = await nextMessage(ws);
    expect(msg).toEqual({ type: "ready" });
    ws.close();
  });

  test("invalid token closes 4401", async () => {
    const ws = await openWs("WRONG");
    const close = await nextClose(ws);
    expect(close.code).toBe(4401);
  });

  test("valid-token second connection supersedes the current owner", async () => {
    // A second hello with the valid token is the same app reconnecting (not a
    // competing owner). It takes over: the new socket gets `ready`, the stale
    // owner is force-closed with 4409. This is what makes a reconnect race-free
    // even when the old socket's TCP close lags the new hello (previously the
    // new, legitimate socket was the one rejected → "socket closed before ready").
    const ws1 = await openWs("secret-token", 1);
    await nextMessage(ws1);
    const ws1Closed = nextClose(ws1);

    const ws2 = await openWs("secret-token", 2);
    const ready = await nextMessage(ws2);
    expect(ready).toEqual({ type: "ready" });

    const close = await ws1Closed;
    expect(close.code).toBe(4409);
    ws2.close();
  });

  test("superseding owner receives bus frames; stale owner does not", async () => {
    const ws1 = await openWs("secret-token", 1);
    await nextMessage(ws1);
    const ws2 = await openWs("secret-token", 2);
    await nextMessage(ws2); // ready — ws2 is now the owner

    const m = createMessage("terminal:output", { terminalId: "s", data: "out" });
    bus.publish(m, "control");

    const got = await nextMessage(ws2);
    expect(got.type).toBe("terminal:output");
    ws2.close();
  });

  test("after owner disconnects, new owner accepted", async () => {
    const ws1 = await openWs("secret-token", 1);
    await nextMessage(ws1);
    ws1.close();
    await new Promise((r) => setTimeout(r, 50));

    const ws2 = await openWs("secret-token", 2);
    const msg = await nextMessage(ws2);
    expect(msg).toEqual({ type: "ready" });
    ws2.close();
  });
});

describe("LocalListener routing", () => {
  test("inbound frame dispatches to bus", async () => {
    const received: any[] = [];
    bus.setInboundHandler((m, c) => received.push({ m, c }));

    const ws = await openWs();
    await nextMessage(ws);

    const m = createMessage("terminal:input", { terminalId: "s", data: "hi" });
    ws.send(JSON.stringify({ channel: "control", ...m }));

    await new Promise((r) => setTimeout(r, 30));
    expect(received).toHaveLength(1);
    expect(received[0].m.type).toBe("terminal:input");
    expect(received[0].c).toBe("control");
    ws.close();
  });

  test("outbound publish reaches owner socket", async () => {
    const ws = await openWs();
    await nextMessage(ws);

    const m = createMessage("terminal:output", { terminalId: "s", data: "out" });
    bus.publish(m, "control");

    const got = await nextMessage(ws);
    expect(got.type).toBe("terminal:output");
    expect(got.channel).toBe("control");
    ws.close();
  });

  test("delivers frames published AFTER owner-connect (no auto-replay)", async () => {
    // After auto-replay removal, the listener delivers frames published
    // AFTER owner-connect. State-restoration on (re)connect is now the
    // App's responsibility via the state.snapshot RPC (covered by
    // tests/rpc-end-to-end.test.ts and Flutter integration).
    const ws = await openWs();
    const ready = await nextMessage(ws);
    expect(ready.type).toBe("ready");

    const tree = createMessage("tree:full", {
      projectId: "p1",
      root: { name: "root", path: "/", type: "directory" as const, children: [] },
    });
    bus.publish(tree, "control");

    const got = await nextMessage(ws);
    expect(got.type).toBe("tree:full");
    ws.close();
  });
});
