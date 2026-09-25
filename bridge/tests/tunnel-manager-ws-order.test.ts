// The WS half of TunnelManager: serveWs(open, peer) opens the real upstream
// and hands back the sink the caller feeds app-side traffic into. A WS tunnel
// is its own ordered QUIC stream whose open record precedes any data, so the
// only buffering here is while the upstream TCP connect is still in flight.
import { expect, test } from "bun:test";
import { STREAM_TUNNEL_DATA_MAX_BYTES } from "antgrid-wire";
import { createConnState } from "../src/conn-state";
import { TunnelManager, type TunnelWsFrame, type TunnelWsPeer } from "../src/tunnel-manager";
import type { StreamSendOutcome } from "../src/peer/stream-records";
import type { TunnelWsOpen } from "../src/tunnel-protocol";

/** Echoes what it is sent, and counts the sockets it currently holds open —
 *  the only way to tell a tunnel the bridge tore down from one it merely
 *  stopped forwarding on. */
function startEchoServer() {
  const state = { open: 0 };
  const server = Bun.serve({
    port: 0,
    fetch(req, server) {
      if (server.upgrade(req)) return;
      return new Response("upgrade required", { status: 426 });
    },
    websocket: {
      open() { state.open += 1; },
      close() { state.open -= 1; },
      message(ws, data) {
        ws.send(data);
      },
    },
  });
  return Object.assign(server, { upstream: state });
}

function makeManager() {
  return new TunnelManager({
    projectId: "project",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
  });
}

/** A fake `TunnelWsPeer`: records what the manager sent toward the app and how
 *  it closed the tunnel. `outcomeFor` stands in for the registry's own send
 *  path — the only two outcomes a real writer reports are "sent" and
 *  "dropped" (`StreamSendOutcome`). */
function makePeer(outcomeFor?: (frame: TunnelWsFrame) => StreamSendOutcome) {
  const sent: TunnelWsFrame[] = [];
  const closes: Array<{ code?: number; reason?: string }> = [];
  const peer: TunnelWsPeer = {
    send: async (frame) => {
      sent.push(frame);
      return outcomeFor?.(frame) ?? "sent";
    },
    close: (code, reason) => { closes.push({ code, reason }); },
  };
  return { sent, closes, peer };
}

function open(tunnelId: string, port: number): TunnelWsOpen {
  return { type: "tunnel:ws-open", tunnelId, port, scheme: "http", path: "/", checkoutId: "main" };
}

async function waitUntil(condition: () => boolean, ms = 2_000): Promise<void> {
  const deadline = Date.now() + ms;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(10);
  }
}

test("frames sent while the upstream handshake is still connecting are replayed in order once it opens", async () => {
  const server = startEchoServer();
  const mgr = makeManager();
  const { sent, peer } = makePeer();
  try {
    const sink = mgr.serveWs(open("early", server.port!), peer);
    // The upstream TCP connect is async, so calling data() right after serveWs
    // returns lands on the pre-connect buffer, not a live socket.
    sink.data({ binary: false, bytes: new TextEncoder().encode("signalr-handshake") });
    sink.data({ binary: true, bytes: new Uint8Array([0, 1, 2, 255]) });

    await waitUntil(() => sent.length === 2);
    expect(new TextDecoder().decode(sent[0].bytes)).toBe("signalr-handshake");
    expect(sent[0].binary).toBe(false);
    expect(sent[1]).toEqual({ binary: true, bytes: new Uint8Array([0, 1, 2, 255]) });
  } finally {
    mgr.stop();
    server.stop(true);
  }
});

test("upstream messages then its close reach the peer as sends, then close", async () => {
  const server = Bun.serve({
    port: 0,
    fetch(req, server) {
      if (server.upgrade(req)) return;
      return new Response("upgrade required", { status: 426 });
    },
    websocket: {
      open(ws) {
        for (const m of ["one", "two", "three"]) ws.send(m);
        ws.close(4000, "bye");
      },
      message() {},
    },
  });
  const mgr = makeManager();
  const events: string[] = [];
  const peer: TunnelWsPeer = {
    send: async (frame) => {
      events.push(`send:${new TextDecoder().decode(frame.bytes)}`);
      return "sent";
    },
    close: (code) => { events.push(`close:${code}`); },
  };
  try {
    mgr.serveWs(open("drain", server.port!), peer);
    await waitUntil(() => events.some((e) => e.startsWith("close:")));
    expect(events).toEqual(["send:one", "send:two", "send:three", "close:4000"]);
  } finally {
    mgr.stop();
    server.stop(true);
  }
});

test("a pre-connect buffer that overflows closes the tunnel rather than splicing", async () => {
  const server = startEchoServer();
  const mgr = makeManager();
  const { sent, closes, peer } = makePeer();
  try {
    const sink = mgr.serveWs(open("overflow", server.port!), peer);
    // 1 MB ceiling: the first frame is over it on its own, so the frames that
    // follow are a stream missing its head.
    sink.data({ binary: false, bytes: new TextEncoder().encode("x".repeat(1024 * 1024 + 10)) });
    sink.data({ binary: false, bytes: new TextEncoder().encode("frame-2") });
    sink.data({ binary: false, bytes: new TextEncoder().encode("frame-3") });

    await waitUntil(() => closes.length > 0);
    expect(closes[0].reason).toContain("buffer overflow");
    await Bun.sleep(50);
    expect(sent).toHaveLength(0);
  } finally {
    mgr.stop();
    server.stop(true);
  }
});

test("stop() closes tunnels the app still believes are live", async () => {
  const server = startEchoServer();
  const mgr = makeManager();
  const { closes, peer } = makePeer();
  try {
    mgr.serveWs(open("live", server.port!), peer);
    // Deliberately NOT awaiting the upstream handshake: a session deleted
    // while a preview page is mid-connect is the case where the socket's own
    // close event never fires, so stop() has to send the frame itself.
    mgr.stop();

    expect(closes).toMatchObject([{ code: 1001, reason: "tunnel manager stopped" }]);
  } finally {
    server.stop(true);
  }
});

// A WS carries a byte stream, so an upstream message the transport could not
// deliver leaves a hole no later frame can fill — the page's own reconnect is
// the only repair, and it needs a close event to start.
test("an upstream message over the tunnel cap closes the tunnel with 1009", async () => {
  const server = startEchoServer();
  const mgr = makeManager();
  const { sent, closes, peer } = makePeer();
  try {
    const sink = mgr.serveWs(open("big", server.port!), peer);
    await waitUntil(() => server.upstream.open === 1);
    // The echo server hands this straight back, oversized on receipt.
    sink.data({ binary: false, bytes: new TextEncoder().encode("x".repeat(STREAM_TUNNEL_DATA_MAX_BYTES + 1)) });

    await waitUntil(() => closes.length > 0);
    expect(closes[0].code).toBe(1009);
    await waitUntil(() => server.upstream.open === 0);
    expect(sent).toHaveLength(0);
  } finally {
    mgr.stop();
    server.stop(true);
  }
});

test("a dropped upstream frame closes the tunnel with 1001", async () => {
  const server = startEchoServer();
  const mgr = makeManager();
  const { closes, peer } = makePeer(() => "dropped");
  try {
    const sink = mgr.serveWs(open("gone", server.port!), peer);
    await waitUntil(() => server.upstream.open === 1);
    sink.data({ binary: false, bytes: new TextEncoder().encode("echo-me") });

    await waitUntil(() => closes.length > 0);
    expect(closes[0].code).toBe(1001);
    await waitUntil(() => server.upstream.open === 0);
  } finally {
    mgr.stop();
    server.stop(true);
  }
});
