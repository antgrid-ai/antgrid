// Gate: tunnel HTTP and WebSocket streams. Every preview HTTP request and
// every preview WebSocket rides its own native QUIC stream instead of the
// project stream's preview channel — `RelayClient.openTunnelHttpStream` /
// `openTunnelWsStream` drive that wire directly, the way
// `gate-terminal-streams.test.ts` drives `openTerminalStream` for the
// terminal stream.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import { STREAM_MAX_TUNNEL_STREAMS_PER_PEER } from "antgrid-wire";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { firstProjectStream, streamSnapshot } from "../support/stream";
import type { TunnelHttpStreamClient } from "../helpers/relay-client";

const BIG = randomBytes(6 * 1024 * 1024);
// +17: larger than one raw write slice (STREAM_RECORD_SLICE_BYTES), so the
// echo proves a body spanning several slices reassembles byte-exact.
const POST_BODY = randomBytes(1 * 1024 * 1024 + 17);

/** The origin every HTTP row tunnels to: a small/big GET, a POST echo that
 *  records whether it was ever reached (the content-length/bodyLength
 *  mismatch row must prove it was NOT), and a `/stall` GET whose body never
 *  completes on its own, so a cancel or an over-cap hold has something to
 *  hold open. `stallCancelled` mirrors `startStreamServer` in
 *  bridge/tests/localhost-fetch.test.ts: the ReadableStream's own `cancel()`
 *  is the only observable difference between the upstream socket actually
 *  closing and the app merely giving up on reading it. */
function startHttpOrigin() {
  const state = { stallCancelled: false, echoHits: 0 };
  const server = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    // `/stall` must stall for as long as a test holds it. Bun's default 10s
    // idle timeout would end the oldest of the cap row's 128 streams while the
    // row is still opening the rest, freeing a slot the row expects held.
    idleTimeout: 0,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/small") {
        return new Response("small-ok", { status: 200, headers: { "content-type": "text/plain" } });
      }
      if (url.pathname === "/big") {
        return new Response(BIG, { headers: { "content-type": "application/octet-stream" } });
      }
      if (url.pathname === "/stall") {
        const body = new ReadableStream<Uint8Array>({
          start(c) {
            c.enqueue(randomBytes(64 * 1024));
          },
          cancel() {
            state.stallCancelled = true;
          },
        });
        return new Response(body, { headers: { "content-type": "application/octet-stream" } });
      }
      if (url.pathname === "/echo-body" && req.method === "POST") {
        state.echoHits++;
        const bytes = new Uint8Array(await req.arrayBuffer());
        return new Response(bytes, { headers: { "content-type": "application/octet-stream" } });
      }
      return new Response("not found", { status: 404 });
    },
  });
  return { server, port: server.port!, state };
}

interface WsOriginData {
  path: string;
}

/** One WS upstream serving two behaviors by path: `/burst` sends 50 messages
 *  then closes 4001 "bye" on open (row 6); any other path just records what
 *  it received and how it was closed, in order (row 7). */
function startWsOrigin() {
  const receivedByPath = new Map<string, Array<{ text?: string; bytes?: Buffer }>>();
  const closesByPath = new Map<string, Array<{ code: number; reason: string }>>();
  const server = Bun.serve<WsOriginData, never>({
    port: 0,
    hostname: "127.0.0.1",
    fetch(req, srv) {
      const url = new URL(req.url);
      if (srv.upgrade(req, { data: { path: url.pathname } })) return;
      return new Response("upgrade required", { status: 426 });
    },
    websocket: {
      open(ws) {
        if (ws.data.path === "/burst") {
          for (let i = 0; i < 50; i++) ws.send(`msg-${i}`);
          ws.close(4001, "bye");
        }
      },
      message(ws, data) {
        const list = receivedByPath.get(ws.data.path) ?? [];
        list.push(typeof data === "string" ? { text: data } : { bytes: Buffer.from(data as Uint8Array) });
        receivedByPath.set(ws.data.path, list);
      },
      close(ws, code, reason) {
        const list = closesByPath.get(ws.data.path) ?? [];
        list.push({ code, reason });
        closesByPath.set(ws.data.path, list);
      },
    },
  });
  return { server, port: server.port!, receivedByPath, closesByPath };
}

async function refusalCodeOf(client: TunnelHttpStreamClient, timeoutMs = 5_000): Promise<string | undefined> {
  try {
    await client.head(timeoutMs);
    return undefined;
  } catch (err: any) {
    return err?.refusal?.code;
  }
}

describe("gate: tunnel HTTP and WebSocket streams", () => {
  let env: TestEnv;
  let streamId: string;
  let http: ReturnType<typeof startHttpOrigin>;
  let ws: ReturnType<typeof startWsOrigin>;

  beforeAll(async () => {
    http = startHttpOrigin();
    ws = startWsOrigin();
    env = await setupTestEnv({ fixtureName: "basic" });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    http?.server.stop(true);
    ws?.server.stop(true);
    await env?.teardown();
  });

  test("a 6 MiB body crosses intact on its own stream while a control verb is answered on the project stream", async () => {
    const client = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/big", headers: {} },
    });

    const framesP = streamSnapshot(env.app, streamId, 20_000);
    const res = await client.response(60_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);

    const frames = await framesP;
    expect(frames.length).toBeGreaterThan(0);
  }, 90_000);

  test("pausing reads mid-body neither resets the stream nor retires the connection, and resuming completes it", async () => {
    const before = env.app.nativeConnectionId;
    const client = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/big", headers: {} },
    });
    await client.head(10_000);

    const gotFirstByte = Date.now() + 5_000;
    while (client.bodyBytesSoFar() === 0 && Date.now() < gotFirstByte) await Bun.sleep(20);
    expect(client.bodyBytesSoFar()).toBeGreaterThan(0);

    client.pauseReading();
    // Let a read already in flight when pauseReading() was called settle,
    // so the sample below is the true, post-pause plateau.
    await Bun.sleep(300);
    const stalled = client.bodyBytesSoFar();
    await Bun.sleep(1_000);
    expect(client.bodyBytesSoFar()).toBe(stalled);

    const frames = await streamSnapshot(env.app, streamId, 20_000);
    expect(frames.length).toBeGreaterThan(0);
    expect(env.app.nativeConnectionId).toBe(before);

    client.resumeReading();
    const res = await client.response(60_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);
    expect(client.bodyBytesSoFar()).toBeGreaterThan(stalled);
  }, 90_000);

  test("cancelling a stalled body closes the upstream request within 5s and leaves the connection usable", async () => {
    http.state.stallCancelled = false;
    const before = env.app.nativeConnectionId;
    const client = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/stall", headers: {} },
    });
    await client.head(10_000);

    const gotFirstByte = Date.now() + 5_000;
    while (client.bodyBytesSoFar() === 0 && Date.now() < gotFirstByte) await Bun.sleep(20);
    expect(client.bodyBytesSoFar()).toBeGreaterThan(0);

    client.cancel();
    const ended = await Promise.race([client.ended, Bun.sleep(5_000).then(() => "timeout" as const)]);
    expect(ended).toBe("truncated");

    const closedDeadline = Date.now() + 5_000;
    while (!http.state.stallCancelled && Date.now() < closedDeadline) await Bun.sleep(20);
    expect(http.state.stallCancelled).toBe(true);

    // A fresh request on a NEW stream still succeeds.
    const follow = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/small", headers: {} },
    });
    const res = await follow.response(10_000);
    expect(res.status).toBe(200);
    expect(res.body.toString("utf8")).toBe("small-ok");

    expect(env.app.nativeConnectionId).toBe(before);
  }, 30_000);

  test("stream cap: the 129th tunnel-http open is refused CAP_EXCEEDED, and cancelling one frees a slot", async () => {
    const clients: TunnelHttpStreamClient[] = [];
    try {
      for (let i = 0; i < STREAM_MAX_TUNNEL_STREAMS_PER_PEER; i++) {
        const client = await env.app.openTunnelHttpStream({
          projectId: env.projectId,
          head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/stall", headers: {} },
        });
        await client.head(10_000);
        clients.push(client);
      }

      const overflow = await env.app.openTunnelHttpStream({
        projectId: env.projectId,
        head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/stall", headers: {} },
      });
      expect(await refusalCodeOf(overflow, 5_000)).toBe("CAP_EXCEEDED");
      expect(await overflow.ended).toBe("refused");

      const frames = await streamSnapshot(env.app, streamId, 10_000);
      expect(frames.length).toBeGreaterThan(0);

      clients[0]!.cancel();
      await clients[0]!.ended;

      const afterCancel = await env.app.openTunnelHttpStream({
        projectId: env.projectId,
        head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/stall", headers: {} },
      });
      const head = await afterCancel.head(10_000);
      expect(head.type).toBe("tunnel:http-head");
      expect(head.status).toBe(200);
      clients.push(afterCancel);
    } finally {
      for (const client of clients) client.cancel();
    }
  }, 120_000);

  test("in-band refusals: an uncatalogued project, a mismatched requestId, and a disagreeing content-length", async () => {
    const uncatalogued = await env.app.openTunnelHttpStream({
      projectId: randomBytes(8).toString("hex"),
      head: { type: "tunnel:http-request", port: http.port, method: "GET", path: "/small", headers: {} },
    });
    expect(await refusalCodeOf(uncatalogued)).toBe("NOT_ALLOWED");
    expect(await uncatalogued.ended).toBe("refused");

    const mismatched = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      requestId: "req-open-mismatch",
      head: {
        type: "tunnel:http-request",
        requestId: "req-head-mismatch",
        port: http.port,
        method: "GET",
        path: "/small",
        headers: {},
      },
    });
    expect(await refusalCodeOf(mismatched)).toBe("INVALID");
    expect(await mismatched.ended).toBe("refused");

    const beforeHits = http.state.echoHits;
    const badLength = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: {
        type: "tunnel:http-request",
        port: http.port,
        method: "POST",
        path: "/echo-body",
        headers: { "content-length": "999" },
      },
      body: new Uint8Array([1, 2, 3]),
    });
    expect(await refusalCodeOf(badLength)).toBe("INVALID");
    expect(await badLength.ended).toBe("refused");
    await Bun.sleep(200);
    expect(http.state.echoHits).toBe(beforeHits);

    const frames = await streamSnapshot(env.app, streamId, 10_000);
    expect(frames.length).toBeGreaterThan(0);
  }, 30_000);

  test("a 1 MiB + 17 byte binary POST body, spanning several write slices, is echoed back byte-exact", async () => {
    const client = await env.app.openTunnelHttpStream({
      projectId: env.projectId,
      head: { type: "tunnel:http-request", port: http.port, method: "POST", path: "/echo-body", headers: {} },
      body: POST_BODY,
    });
    const res = await client.response(30_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(POST_BODY)).toBe(true);
  }, 40_000);

  test("WS close order: 50 queued messages arrive in order, then the close record, then the end", async () => {
    const client = await env.app.openTunnelWsStream({
      projectId: env.projectId,
      open: { type: "tunnel:ws-open", port: ws.port, path: "/burst" },
    });

    const texts: string[] = [];
    for (let i = 0; i < 50; i++) {
      const record = await client.next((r) => r.kind === "text" || r.kind === "close", 10_000);
      if (record.kind !== "text") throw new Error(`expected a text record at index ${i}, got "${record.kind}"`);
      texts.push(record.text);
    }
    expect(texts).toEqual(Array.from({ length: 50 }, (_, i) => `msg-${i}`));

    const close = await client.next((r) => r.kind === "close", 10_000);
    expect(close.kind).toBe("close");
    if (close.kind === "close") {
      expect(close.code).toBe(4001);
      expect(close.reason).toBe("bye");
    }
    await client.ended;
  }, 20_000);

  test("WS toward the upstream: text and binary frames arrive in order, and close(1000) reaches it as a close", async () => {
    const client = await env.app.openTunnelWsStream({
      projectId: env.projectId,
      open: { type: "tunnel:ws-open", port: ws.port, path: "/echo-upstream" },
    });

    await client.sendText("hello");
    await client.sendBinary(Uint8Array.from([1, 2, 3]));
    await client.close(1000, "done");
    await client.ended;

    const deadline = Date.now() + 5_000;
    while ((ws.closesByPath.get("/echo-upstream")?.length ?? 0) === 0 && Date.now() < deadline) {
      await Bun.sleep(20);
    }

    const received = ws.receivedByPath.get("/echo-upstream") ?? [];
    expect(received.length).toBe(2);
    expect(received[0]).toEqual({ text: "hello" });
    expect(received[1]?.bytes && Buffer.from(received[1].bytes).equals(Buffer.from([1, 2, 3]))).toBe(true);

    const closes = ws.closesByPath.get("/echo-upstream") ?? [];
    expect(closes[0]?.code).toBe(1000);
  }, 20_000);
});
