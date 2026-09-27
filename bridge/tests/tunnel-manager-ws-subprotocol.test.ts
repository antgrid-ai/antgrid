// Retargeted from onWsOpen/onWsClose to serveWs/sink.closed —
// the assertions below keep the same meaning as before the rewrite, just
// against the new API: a peer records what the manager sent it instead of a
// shared `sendTunnel` JSON log.
import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import net from "node:net";
import { createConnState } from "../src/conn-state";
import { TunnelManager, type TunnelWsFrame, type TunnelWsPeer } from "../src/tunnel-manager";
import type { TunnelWsOpen } from "../src/tunnel-protocol";

/** A Vite-shaped upstream: the upgrade is answered only when the request
 *  names `vite-hmr`, and is otherwise left unanswered — never refused. */
function startViteLikeServer(seen: Array<string | null>) {
  return Bun.serve({
    port: 0,
    fetch(req, server) {
      const protocol = req.headers.get("sec-websocket-protocol");
      seen.push(protocol);
      const requested = (protocol ?? "").split(",").map((s) => s.trim());
      if (requested.includes("vite-hmr")) {
        if (server.upgrade(req, { headers: { "Sec-WebSocket-Protocol": "vite-hmr" } })) return;
      }
      return new Promise<Response>(() => {});
    },
    websocket: {
      open(ws) {
        ws.send('{"type":"connected"}');
      },
      message() {},
    },
  });
}

function makeManager(opts: { wsAbandonedMax?: number } = {}) {
  return new TunnelManager({
    projectId: "project",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
    ...opts,
  });
}

/** Tags every send/close onto a shared log so a test can filter by which
 *  `serveWs` call (which peer) produced it — the new API hands the manager a
 *  distinct peer per stream rather than one shared `sendTunnel` sink. */
function makePeer(log: Array<Record<string, unknown>>, tag: string): TunnelWsPeer {
  return {
    send: async (frame: TunnelWsFrame) => {
      log.push({
        kind: "data",
        tag,
        binary: frame.binary,
        text: frame.binary ? undefined : new TextDecoder().decode(frame.bytes),
      });
      return "sent";
    },
    close: (code, reason) => { log.push({ kind: "close", tag, code, reason }); },
  };
}

async function waitUntil(condition: () => boolean, ms = 2_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(10);
  }
}

function openReq(tunnelId: string, port: number, headers?: Record<string, string>): TunnelWsOpen {
  return {
    type: "tunnel:ws-open",
    tunnelId,
    port,
    scheme: "http",
    path: "/",
    ...(headers ? { headers } : {}),
    checkoutId: "main",
  };
}

test("the browser's subprotocol reaches the dev server, and its socket opens", async () => {
  const seen: Array<string | null> = [];
  const server = startViteLikeServer(seen);
  const manager = makeManager();
  const log: Array<Record<string, unknown>> = [];
  try {
    manager.serveWs(openReq("hmr", server.port!, { "sec-websocket-protocol": "vite-hmr", cookie: "a=b" }), makePeer(log, "hmr"));
    await waitUntil(() => log.some((e) => e.kind === "data"));
    expect(seen).toEqual(["vite-hmr"]);
    expect(log.find((e) => e.kind === "data")).toMatchObject({ text: '{"type":"connected"}' });
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("every requested subprotocol is offered upstream, in order", async () => {
  const seen: Array<string | null> = [];
  const server = startViteLikeServer(seen);
  const manager = makeManager();
  const log: Array<Record<string, unknown>> = [];
  try {
    manager.serveWs(openReq("multi", server.port!, { "Sec-WebSocket-Protocol": "graphql-ws, vite-hmr" }), makePeer(log, "multi"));
    await waitUntil(() => log.some((e) => e.kind === "data"));
    expect(seen).toHaveLength(1);
    expect(seen[0]!.split(",").map((s) => s.trim())).toEqual(["graphql-ws", "vite-hmr"]);
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("a browser that asked for no subprotocol sends none upstream", async () => {
  const seen: Array<string | null> = [];
  const server = Bun.serve({
    port: 0,
    fetch(req, server) {
      seen.push(req.headers.get("sec-websocket-protocol"));
      if (server.upgrade(req)) return;
      return new Response("upgrade required", { status: 426 });
    },
    websocket: {
      open(ws) {
        ws.send("hi");
      },
      message() {},
    },
  });
  const manager = makeManager();
  const log: Array<Record<string, unknown>> = [];
  try {
    manager.serveWs(openReq("plain", server.port!, { cookie: "a=b" }), makePeer(log, "plain"));
    await waitUntil(() => log.some((e) => e.kind === "data"));
    expect(seen).toEqual([null]);
  } finally {
    manager.stop();
    server.stop(true);
  }
});

/** A raw listener that accepts the TCP connection, reads the upgrade request
 *  and answers nothing until told to — what a dev server that ignores an
 *  upgrade looks like from the bridge's side. Records how each connection
 *  ends, because the distinction under test is FIN versus RESET. */
function startSilentUpstream() {
  const conns: Array<{
    socket: net.Socket;
    request: string;
    frames: Buffer[];
    errors: string[];
    ended: boolean;
  }> = [];
  const server = net.createServer((socket) => {
    const conn = { socket, request: "", frames: [] as Buffer[], errors: [] as string[], ended: false };
    conns.push(conn);
    let upgraded = false;
    socket.on("data", (chunk) => {
      const bytes = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      if (upgraded) {
        conn.frames.push(bytes);
        // Complete the close handshake: a client that sent Close waits for
        // the peer's Close before it FINs, as the RFC has it.
        if ((bytes[0]! & 0x0f) === 0x08) socket.end(Buffer.from([0x88, 0x02, 0x03, 0xe8]));
        return;
      }
      conn.request += bytes.toString("latin1");
      if (conn.request.includes("\r\n\r\n")) upgraded = true;
    });
    socket.on("error", (err) => conn.errors.push((err as NodeJS.ErrnoException).code ?? err.message));
    socket.on("end", () => {
      conn.ended = true;
    });
  });
  server.listen(0, "127.0.0.1");
  const port = () => (server.address() as net.AddressInfo).port;
  const answer = (conn: (typeof conns)[number]) => {
    const key = /sec-websocket-key:\s*(\S+)/i.exec(conn.request)?.[1] ?? "";
    const accept = createHash("sha1")
      .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
      .digest("base64");
    conn.socket.write(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );
  };
  return { conns, port, answer, close: () => server.close() };
}

test("closing a tunnel mid-handshake never resets the upstream socket", async () => {
  const upstream = startSilentUpstream();
  const manager = makeManager();
  const log: Array<Record<string, unknown>> = [];
  try {
    const sink = manager.serveWs(openReq("hanging", upstream.port()), makePeer(log, "hanging"));
    await waitUntil(() => upstream.conns.length === 1 && upstream.conns[0]!.request.includes("\r\n\r\n"));
    const conn = upstream.conns[0]!;

    sink.closed();
    await Bun.sleep(300);
    // Still connecting, still open on the far side: no FIN, and above all no
    // RESET — a Node dev server that ignored this upgrade holds the socket with
    // no error listener, and a reset there is an uncaught ECONNRESET.
    expect(conn.errors).toEqual([]);
    expect(conn.ended).toBe(false);
    expect(conn.socket.destroyed).toBe(false);

    // The moment the server does answer, the parked socket closes gracefully.
    upstream.answer(conn);
    await waitUntil(() => conn.frames.length > 0);
    expect(conn.frames[0]![0]! & 0x0f).toBe(0x08); // a WebSocket close frame
    await waitUntil(() => conn.ended || conn.socket.destroyed);
    expect(conn.errors).toEqual([]);
  } finally {
    manager.stop();
    upstream.close();
  }
});

test("a parked handshake that later completes never speaks for its tunnel id", async () => {
  const upstream = startSilentUpstream();
  const manager = makeManager();
  const log: Array<Record<string, unknown>> = [];
  try {
    const first = manager.serveWs(openReq("reused", upstream.port()), makePeer(log, "first"));
    await waitUntil(() => upstream.conns.length === 1 && upstream.conns[0]!.request.includes("\r\n\r\n"));
    first.closed();

    // The same id names a fresh tunnel while the first socket is still parked.
    manager.serveWs(openReq("reused", upstream.port()), makePeer(log, "second"));
    await waitUntil(() => upstream.conns.length === 2 && upstream.conns[1]!.request.includes("\r\n\r\n"));

    // The parked socket opens, is closed, and the server answers its close.
    // Nothing of that may reach the app as the fresh tunnel's news.
    const parked = upstream.conns[0]!;
    upstream.answer(parked);
    await waitUntil(() => parked.ended || parked.socket.destroyed);
    await Bun.sleep(100);
    expect(log.filter((e) => e.tag === "first")).toEqual([]);
  } finally {
    manager.stop();
    upstream.close();
  }
});

test("the park is bounded: past the cap the oldest handshake is cut", async () => {
  const upstream = startSilentUpstream();
  const manager = makeManager({ wsAbandonedMax: 1 });
  const log: Array<Record<string, unknown>> = [];
  try {
    const first = manager.serveWs(openReq("first", upstream.port()), makePeer(log, "first"));
    await waitUntil(() => upstream.conns.length === 1);
    first.closed();

    const second = manager.serveWs(openReq("second", upstream.port()), makePeer(log, "second"));
    await waitUntil(() => upstream.conns.length === 2);
    second.closed();

    const [firstConn, secondConn] = upstream.conns as [(typeof upstream.conns)[number], (typeof upstream.conns)[number]];
    await waitUntil(() => firstConn.errors.length > 0 || firstConn.ended || firstConn.socket.destroyed);
    await Bun.sleep(200);
    expect(secondConn.errors).toEqual([]);
    expect(secondConn.ended).toBe(false);
    expect(secondConn.socket.destroyed).toBe(false);
  } finally {
    manager.stop();
    upstream.close();
  }
});

test("a subprotocol Bun's constructor refuses ends the one tunnel, not the host", async () => {
  const seen: Array<string | null> = [];
  const server = startViteLikeServer(seen);
  const manager = makeManager();
  const log: Array<Record<string, unknown>> = [];
  try {
    // `=` is not an RFC 6455 token, and Bun's constructor throws SyntaxError for
    // it. Nothing between the registry's read loop and here catches, and an
    // uncaught exception takes down every agent on the machine.
    manager.serveWs(openReq("bad", server.port!, { "sec-websocket-protocol": "bearer.abc=" }), makePeer(log, "bad"));
    expect(log).toEqual([{ kind: "close", tag: "bad", code: undefined, reason: "upstream connection could not be opened" }]);
    expect(seen).toEqual([]);

    // The refusal must not have left the id mapped: a browser retry still works.
    const log2: Array<Record<string, unknown>> = [];
    manager.serveWs(openReq("bad", server.port!, { "sec-websocket-protocol": "vite-hmr" }), makePeer(log2, "bad2"));
    await waitUntil(() => log2.some((e) => e.kind === "data"));
  } finally {
    manager.stop();
    server.stop(true);
  }
});
