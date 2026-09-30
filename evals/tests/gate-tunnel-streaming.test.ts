// Gate: tunnel-tcp streams. Every connection the phone's preview forwarder
// accepts rides its own native QUIC stream and is piped, byte for byte, to a
// TCP port on the bridge's machine. `RelayClient.openTunnelTcpStream` drives
// that wire directly, the way `gate-terminal-streams.test.ts` drives
// `openTerminalStream`; HTTP and WebSocket are spoken by hand over it
// (`support/raw-http.ts`) so nothing but the bridge can have touched a byte.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import { STREAM_MAX_TUNNEL_STREAMS_PER_PEER } from "antgrid-wire";
import { setupTestEnv, setMobileAccess, type TestEnv } from "../helpers/harness";
import { firstProjectStream, streamSnapshot } from "../support/stream";
import type { TunnelTcpStreamClient } from "../helpers/relay-client";
import {
  buildRequest,
  buildWsHandshake,
  decodeWsFrames,
  encodeWsFrame,
  fetchOverTunnel,
  parseHead,
} from "../support/raw-http";

const BIG = randomBytes(6 * 1024 * 1024);
// +17: larger than one raw write slice (STREAM_RECORD_SLICE_BYTES), so the
// echo proves a body spanning several slices reassembles byte-exact.
const POST_BODY = randomBytes(1 * 1024 * 1024 + 17);

/** The origin every HTTP row tunnels to: a small/big GET, a POST echo, a
 *  header echo (so a row can prove request headers arrived unmodified and
 *  response headers were not decorated), and a `/stall` GET whose body never
 *  completes on its own, so a reset or an over-cap hold has something to hold
 *  open. `stallCancelled` is the ReadableStream's own `cancel()`, the only
 *  observable difference between the upstream socket closing and the app
 *  merely giving up on reading it. */
function startHttpOrigin() {
  const state = { stallCancelled: false };
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
      if (url.pathname === "/headers") {
        return new Response(JSON.stringify(Object.fromEntries(req.headers)), { headers: { "content-type": "application/json" } });
      }
      if (url.pathname === "/cookies") {
        const headers = new Headers({ "content-type": "text/plain" });
        headers.append("set-cookie", "a=1; Path=/");
        headers.append("set-cookie", "b=2; Path=/; HttpOnly");
        return new Response("cookies", { headers });
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
 *  then closes 4001 "bye" on open; any other path echoes every message. */
function startWsOrigin() {
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
        ws.send(data);
      },
    },
  });
  return { server, port: server.port! };
}

/** A port nothing is listening on: bind an ephemeral one, then release it. */
function closedPort(): number {
  const probe = Bun.serve({ port: 0, hostname: "127.0.0.1", fetch: () => new Response("") });
  const port = probe.port!;
  probe.stop(true);
  return port;
}

async function refusalCodeOf(client: TunnelTcpStreamClient, timeoutMs = 5_000): Promise<string | undefined> {
  try {
    await client.ready(timeoutMs);
    return undefined;
  } catch (err: any) {
    return err?.refusal?.code;
  }
}

describe("gate: tunnel-tcp streams", () => {
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

  const openTcp = (port: number, extra: { connId?: string; open?: Record<string, unknown>; projectId?: string } = {}) =>
    env.app.openTunnelTcpStream({ projectId: extra.projectId ?? env.projectId, port, connId: extra.connId, open: extra.open });

  test("a 6 MiB HTTP body crosses intact while a control verb is answered on the project stream", async () => {
    const client = await openTcp(http.port);
    const framesP = streamSnapshot(env.app, streamId, 20_000);
    const res = await fetchOverTunnel(client, buildRequest({ method: "GET", path: "/big", port: http.port }), 60_000);
    expect(res.status).toBe(200);
    expect(res.body.equals(BIG)).toBe(true);

    const frames = await framesP;
    expect(frames.length).toBeGreaterThan(0);
  }, 90_000);

  test("request and response headers cross unmodified: nothing is added, dropped or merged", async () => {
    const echo = await fetchOverTunnel(
      await openTcp(http.port),
      buildRequest({
        method: "GET",
        path: "/headers",
        port: http.port,
        headers: { origin: "http://localhost:5173", referer: "http://localhost:5173/app", "x-custom-header": "kept as sent" },
      }),
    );
    const seen = JSON.parse(echo.body.toString("utf8"));
    expect(seen.origin).toBe("http://localhost:5173");
    expect(seen.referer).toBe("http://localhost:5173/app");
    expect(seen["x-custom-header"]).toBe("kept as sent");
    expect(seen.host).toBe(`localhost:${http.port}`);

    const cookies = await fetchOverTunnel(await openTcp(http.port), buildRequest({ method: "GET", path: "/cookies", port: http.port }));
    expect(cookies.headers.get("set-cookie")).toEqual(["a=1; Path=/", "b=2; Path=/; HttpOnly"]);
    // A tunnel that parsed and re-emitted HTTP would stamp its own defaults here.
    expect(cookies.headers.has("x-powered-by")).toBe(false);
    expect(cookies.headers.has("x-frame-options")).toBe(false);
    expect(cookies.headers.has("x-content-type-options")).toBe(false);
  }, 30_000);

  test("pausing reads mid-body neither resets the stream nor retires the connection, and resuming completes it", async () => {
    const before = env.app.nativeConnectionId;
    const client = await openTcp(http.port);
    await client.ready(10_000);
    await client.send(buildRequest({ method: "GET", path: "/big", port: http.port }));

    await client.waitFor((b) => b.length > 0, 5_000);
    client.pauseReading();
    // Let a read already in flight when pauseReading() was called settle,
    // so the sample below is the true, post-pause plateau.
    await Bun.sleep(300);
    const stalled = client.bytesSoFar();
    await Bun.sleep(1_000);
    expect(client.bytesSoFar()).toBe(stalled);

    const frames = await streamSnapshot(env.app, streamId, 20_000);
    expect(frames.length).toBeGreaterThan(0);
    expect(env.app.nativeConnectionId).toBe(before);

    client.resumeReading();
    expect(await Promise.race([client.ended, Bun.sleep(60_000).then(() => "timeout" as const)])).toBe("fin");
    const bytes = client.received();
    const head = parseHead(bytes)!;
    expect(head.status).toBe(200);
    expect(bytes.subarray(head.bodyStart).equals(BIG)).toBe(true);
    expect(client.bytesSoFar()).toBeGreaterThan(stalled);
  }, 90_000);

  test("resetting a stalled connection closes the upstream within 5s and leaves the native connection usable", async () => {
    http.state.stallCancelled = false;
    const before = env.app.nativeConnectionId;
    const client = await openTcp(http.port);
    await client.ready(10_000);
    await client.send(buildRequest({ method: "GET", path: "/stall", port: http.port }));
    await client.waitFor((b) => b.length > 0, 5_000);

    client.reset();
    const deadline = Date.now() + 5_000;
    while (!http.state.stallCancelled && Date.now() < deadline) await Bun.sleep(20);
    expect(http.state.stallCancelled).toBe(true);

    const follow = await fetchOverTunnel(await openTcp(http.port), buildRequest({ method: "GET", path: "/small", port: http.port }), 10_000);
    expect(follow.status).toBe(200);
    expect(follow.body.toString("utf8")).toBe("small-ok");
    expect(env.app.nativeConnectionId).toBe(before);
  }, 30_000);

  test("stream cap: the 129th tunnel-tcp open is refused CAP_EXCEEDED, and resetting one frees a slot", async () => {
    const clients: TunnelTcpStreamClient[] = [];
    try {
      for (let i = 0; i < STREAM_MAX_TUNNEL_STREAMS_PER_PEER; i++) {
        const client = await openTcp(http.port);
        await client.ready(10_000);
        clients.push(client);
      }

      const overflow = await openTcp(http.port);
      expect(await refusalCodeOf(overflow, 5_000)).toBe("CAP_EXCEEDED");
      expect(await overflow.ended).toBe("refused");

      const frames = await streamSnapshot(env.app, streamId, 10_000);
      expect(frames.length).toBeGreaterThan(0);

      clients[0]!.reset();
      await clients[0]!.ended;

      const afterReset = await openTcp(http.port);
      await afterReset.ready(10_000);
      clients.push(afterReset);
    } finally {
      for (const client of clients) client.reset();
    }
  }, 120_000);

  test("in-band refusals: a mismatched connId, an uncatalogued project, and a checkout that does not exist", async () => {
    const mismatched = await openTcp(http.port, { connId: "conn-open-mismatch", open: { connId: "conn-head-mismatch" } });
    expect(await refusalCodeOf(mismatched)).toBe("INVALID");
    expect(await mismatched.ended).toBe("refused");

    const uncatalogued = await openTcp(http.port, { projectId: randomBytes(8).toString("hex") });
    expect(await refusalCodeOf(uncatalogued)).toBe("NOT_ALLOWED");
    expect(await uncatalogued.ended).toBe("refused");

    const missingCheckout = await openTcp(http.port, { open: { checkoutId: "no-such-checkout" } });
    expect(await refusalCodeOf(missingCheckout)).toBe("NOT_ALLOWED");
    expect(await missingCheckout.ended).toBe("refused");

    const frames = await streamSnapshot(env.app, streamId, 10_000);
    expect(frames.length).toBeGreaterThan(0);
  }, 30_000);

  test("a port nothing listens on answers tunnel:tcp-error and ends", async () => {
    const client = await openTcp(closedPort());
    const err: any = await client.ready(15_000).then(() => null, (e) => e);
    expect(err?.tcpError?.type).toBe("tunnel:tcp-error");
    expect(err?.tcpError?.connId).toBe(client.connId);
    expect(await client.ended).toBe("upstream-error");
  }, 30_000);

  test("a probe reports plaintext for an HTTP dev server and pipes nothing", async () => {
    const client = await env.app.openTunnelTcpStream({ projectId: env.projectId, port: http.port, probe: true });
    expect(await client.ready(10_000)).toEqual({ tls: false });
    expect(await client.ended).toBe("fin");
    expect(client.bytesSoFar()).toBe(0);
  }, 20_000);

  test("a 1 MiB + 17 byte binary POST body, spanning several write slices, is echoed back byte-exact", async () => {
    const res = await fetchOverTunnel(
      await openTcp(http.port),
      buildRequest({ method: "POST", path: "/echo-body", port: http.port, body: POST_BODY }),
      30_000,
    );
    expect(res.status).toBe(200);
    expect(res.body.equals(POST_BODY)).toBe(true);
  }, 40_000);

  test("a WebSocket upgrade completes through the tunnel and frames echo both ways, binary intact", async () => {
    const client = await openTcp(ws.port);
    await client.ready(10_000);
    const handshake = buildWsHandshake(ws.port, "/echo", { origin: `http://localhost:${ws.port}` });
    await client.send(handshake.request);

    const bytes = await client.waitFor((b) => parseHead(b) !== null, 10_000);
    const head = parseHead(bytes)!;
    expect(head.status).toBe(101);
    expect(head.headers.get("sec-websocket-accept")).toEqual([handshake.expectedAccept]);

    const binary = randomBytes(70_000);
    await client.send(Buffer.concat([encodeWsFrame(0x1, Buffer.from("hello")), encodeWsFrame(0x2, binary)]));
    const all = await client.waitFor((b) => decodeWsFrames(b.subarray(head.bodyStart)).length >= 2, 10_000);
    const frames = decodeWsFrames(all.subarray(head.bodyStart));
    expect(frames[0]!.opcode).toBe(0x1);
    expect(frames[0]!.payload.toString("utf8")).toBe("hello");
    expect(frames[1]!.opcode).toBe(0x2);
    expect(frames[1]!.payload.equals(binary)).toBe(true);

    await client.send(encodeWsFrame(0x8, Buffer.from([0x03, 0xe8])));
    await client.finish();
    expect(await Promise.race([client.ended, Bun.sleep(5_000).then(() => "timeout" as const)])).toBe("fin");
  }, 30_000);

  test("WebSocket order: 50 queued messages arrive in order, then the close frame, then the end", async () => {
    const client = await openTcp(ws.port);
    await client.ready(10_000);
    await client.send(buildWsHandshake(ws.port, "/burst").request);
    expect(await Promise.race([client.ended, Bun.sleep(10_000).then(() => "timeout" as const)])).toBe("fin");

    const bytes = client.received();
    const head = parseHead(bytes)!;
    expect(head.status).toBe(101);
    const frames = decodeWsFrames(bytes.subarray(head.bodyStart));
    expect(frames.slice(0, 50).map((f) => f.payload.toString("utf8"))).toEqual(Array.from({ length: 50 }, (_, i) => `msg-${i}`));
    const close = frames[50]!;
    expect(close.opcode).toBe(0x8);
    expect(close.payload.readUInt16BE(0)).toBe(4001);
    expect(close.payload.subarray(2).toString("utf8")).toBe("bye");
  }, 30_000);

  // Last: switching the machine off retires the native connection for good.
  test("switching remote access off ends a live tunnel and closes its upstream socket", async () => {
    http.state.stallCancelled = false;
    const client = await openTcp(http.port);
    await client.ready(10_000);
    await client.send(buildRequest({ method: "GET", path: "/stall", port: http.port }));
    await client.waitFor((b) => b.length > 0, 5_000);

    await setMobileAccess(env.abDir, false);

    expect(await Promise.race([client.ended, Bun.sleep(10_000).then(() => "timeout" as const)])).not.toBe("timeout");
    const deadline = Date.now() + 5_000;
    while (!http.state.stallCancelled && Date.now() < deadline) await Bun.sleep(20);
    expect(http.state.stallCancelled).toBe(true);
  }, 30_000);
});
