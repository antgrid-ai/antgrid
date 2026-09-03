import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import net from "node:net";
import { createConnState } from "../src/conn-state";
import { TunnelManager } from "../src/tunnel-manager";

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
  const sent: Record<string, unknown>[] = [];
  const manager = new TunnelManager({
    projectId: "project",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendTunnel: (data) => sent.push(data as Record<string, unknown>),
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
    ...opts,
  });
  return { manager, sent };
}

async function waitUntil(condition: () => boolean, ms = 2_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(10);
  }
}

function open(manager: TunnelManager, tunnelId: string, port: number, headers?: Record<string, string>) {
  manager.onWsOpen({
    type: "tunnel:ws-open",
    tunnelId,
    port,
    scheme: "http",
    path: "/",
    ...(headers ? { headers } : {}),
    checkoutId: "main",
  });
}

test("the browser's subprotocol reaches the dev server, and its socket opens", async () => {
  const seen: Array<string | null> = [];
  const server = startViteLikeServer(seen);
  const { manager, sent } = makeManager();
  try {
    open(manager, "hmr", server.port!, { "sec-websocket-protocol": "vite-hmr", cookie: "a=b" });
    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-data"));
    expect(seen).toEqual(["vite-hmr"]);
    expect(sent.find((m) => m.type === "tunnel:ws-data")).toMatchObject({
      data: '{"type":"connected"}',
    });
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("every requested subprotocol is offered upstream, in order", async () => {
  const seen: Array<string | null> = [];
  const server = startViteLikeServer(seen);
  const { manager, sent } = makeManager();
  try {
    open(manager, "multi", server.port!, { "Sec-WebSocket-Protocol": "graphql-ws, vite-hmr" });
    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-data"));
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
  const { manager, sent } = makeManager();
  try {
    open(manager, "plain", server.port!, { cookie: "a=b" });
    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-data"));
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
  const { manager } = makeManager();
  try {
    open(manager, "hanging", upstream.port());
    await waitUntil(() => upstream.conns.length === 1 && upstream.conns[0]!.request.includes("\r\n\r\n"));
    const conn = upstream.conns[0]!;

    manager.onWsClose({ type: "tunnel:ws-close", tunnelId: "hanging", checkoutId: "main" });
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
  const { manager, sent } = makeManager();
  try {
    open(manager, "reused", upstream.port());
    await waitUntil(() => upstream.conns.length === 1 && upstream.conns[0]!.request.includes("\r\n\r\n"));
    manager.onWsClose({ type: "tunnel:ws-close", tunnelId: "reused", checkoutId: "main" });

    // The same id names a fresh tunnel while the first socket is still parked.
    open(manager, "reused", upstream.port());
    await waitUntil(() => upstream.conns.length === 2 && upstream.conns[1]!.request.includes("\r\n\r\n"));

    // The parked socket opens, is closed, and the server answers its close.
    // Nothing of that may reach the app as the fresh tunnel's news.
    const parked = upstream.conns[0]!;
    upstream.answer(parked);
    await waitUntil(() => parked.ended || parked.socket.destroyed);
    await Bun.sleep(100);
    expect(sent.filter((m) => m.type === "tunnel:ws-close")).toEqual([]);
    expect(sent.filter((m) => m.type === "tunnel:ws-data")).toEqual([]);
  } finally {
    manager.stop();
    upstream.close();
  }
});

test("the park is bounded: past the cap the oldest handshake is cut", async () => {
  const upstream = startSilentUpstream();
  const { manager } = makeManager({ wsAbandonedMax: 1 });
  try {
    open(manager, "first", upstream.port());
    await waitUntil(() => upstream.conns.length === 1);
    manager.onWsClose({ type: "tunnel:ws-close", tunnelId: "first", checkoutId: "main" });

    open(manager, "second", upstream.port());
    await waitUntil(() => upstream.conns.length === 2);
    manager.onWsClose({ type: "tunnel:ws-close", tunnelId: "second", checkoutId: "main" });

    const [first, second] = upstream.conns as [(typeof upstream.conns)[number], (typeof upstream.conns)[number]];
    await waitUntil(() => first.errors.length > 0 || first.ended || first.socket.destroyed);
    await Bun.sleep(200);
    expect(second.errors).toEqual([]);
    expect(second.ended).toBe(false);
    expect(second.socket.destroyed).toBe(false);
  } finally {
    manager.stop();
    upstream.close();
  }
});

test("a subprotocol Bun's constructor refuses ends the one tunnel, not the host", async () => {
  const seen: Array<string | null> = [];
  const server = startViteLikeServer(seen);
  const { manager, sent } = makeManager();
  try {
    // `=` is not an RFC 6455 token, and Bun's constructor throws SyntaxError for
    // it. Nothing between the relay's message listener and here catches, and an
    // uncaught exception takes down every agent on the machine.
    open(manager, "bad", server.port!, { "sec-websocket-protocol": "bearer.abc=" });
    expect(sent).toEqual([
      {
        type: "tunnel:ws-close",
        tunnelId: "bad",
        reason: "upstream connection could not be opened",
        checkoutId: "main",
      },
    ]);
    expect(seen).toEqual([]);

    // The refusal must not have left the id mapped: a browser retry still works.
    open(manager, "bad", server.port!, { "sec-websocket-protocol": "vite-hmr" });
    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-data"));
  } finally {
    manager.stop();
    server.stop(true);
  }
});
