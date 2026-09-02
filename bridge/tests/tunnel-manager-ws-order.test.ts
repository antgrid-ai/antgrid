import { expect, test } from "bun:test";
import { createConnState } from "../src/conn-state";
import { TunnelManager } from "../src/tunnel-manager";

function startEchoServer() {
  return Bun.serve({
    port: 0,
    fetch(req, server) {
      if (server.upgrade(req)) return;
      return new Response("upgrade required", { status: 426 });
    },
    websocket: {
      message(ws, data) {
        ws.send(data);
      },
    },
  });
}

function makeManager(opts: { wsPreopenTtlMs?: number } = {}) {
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

async function waitUntil(condition: () => boolean): Promise<void> {
  const deadline = Date.now() + 2_000;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error("condition was not met");
    await Bun.sleep(10);
  }
}

test("data arriving before open is replayed upstream in order", async () => {
  const server = startEchoServer();
  const { manager, sent } = makeManager();
  try {
    manager.onWsData({
      type: "tunnel:ws-data",
      tunnelId: "early",
      data: "signalr-handshake",
      checkoutId: "main",
    });
    manager.onWsData({
      type: "tunnel:ws-data",
      tunnelId: "early",
      data: Buffer.from([0, 1, 2, 255]).toString("base64"),
      binary: true,
      checkoutId: "main",
    });
    manager.onWsOpen({
      type: "tunnel:ws-open",
      tunnelId: "early",
      port: server.port!,
      scheme: "http",
      path: "/",
      checkoutId: "main",
    });

    await waitUntil(
      () => sent.filter((m) => m.type === "tunnel:ws-data").length === 2,
    );
    const frames = sent.filter((m) => m.type === "tunnel:ws-data");
    expect(frames[0]).toMatchObject({ data: "signalr-handshake" });
    expect(frames[0].binary).toBeUndefined();
    expect(frames[1]).toMatchObject({ data: "AAEC/w==", binary: true });
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("an open that misses the pre-open TTL is refused, not started mid-stream", async () => {
  const server = startEchoServer();
  const { manager, sent } = makeManager({ wsPreopenTtlMs: 20 });
  try {
    manager.onWsData({
      type: "tunnel:ws-data",
      tunnelId: "expired",
      data: "stale",
      checkoutId: "main",
    });
    await Bun.sleep(50);
    manager.onWsOpen({
      type: "tunnel:ws-open",
      tunnelId: "expired",
      port: server.port!,
      scheme: "http",
      path: "/",
      checkoutId: "main",
    });

    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-close"));
    // The lost prefix must reach the browser as a close it can reconnect from.
    // Relaying the tail into a live upstream is the failure this guards.
    expect(sent.filter((m) => m.type === "tunnel:ws-data")).toHaveLength(0);

    // And the refusal is durable: frames still in flight behind the open must
    // not quietly start a second, tail-only buffer for the same tunnelId.
    manager.onWsData({
      type: "tunnel:ws-data",
      tunnelId: "expired",
      data: "post-expiry",
      checkoutId: "main",
    });
    manager.onWsOpen({
      type: "tunnel:ws-open",
      tunnelId: "expired",
      port: server.port!,
      scheme: "http",
      path: "/",
      checkoutId: "main",
    });
    await Bun.sleep(50);
    expect(sent.filter((m) => m.type === "tunnel:ws-data")).toHaveLength(0);
    expect(sent.filter((m) => m.type === "tunnel:ws-close")).toHaveLength(2);
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("a pre-open buffer that overflows refuses its open rather than splicing", async () => {
  const server = startEchoServer();
  const { manager, sent } = makeManager();
  try {
    // 1 MB ceiling: the first frame is over it on its own, so the frames that
    // follow are a stream missing its head.
    manager.onWsData({
      type: "tunnel:ws-data",
      tunnelId: "overflow",
      data: "x".repeat(1024 * 1024 + 10),
      checkoutId: "main",
    });
    for (const data of ["frame-2", "frame-3"]) {
      manager.onWsData({
        type: "tunnel:ws-data",
        tunnelId: "overflow",
        data,
        checkoutId: "main",
      });
    }
    manager.onWsOpen({
      type: "tunnel:ws-open",
      tunnelId: "overflow",
      port: server.port!,
      scheme: "http",
      path: "/",
      checkoutId: "main",
    });

    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-close"));
    await Bun.sleep(50);
    expect(sent.filter((m) => m.type === "tunnel:ws-data")).toHaveLength(0);
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("closed tunnels do not starve a live one out of the pre-open table", async () => {
  const server = startEchoServer();
  const { manager, sent } = makeManager();
  try {
    // A dev server in a reconnect loop churns a fresh tunnelId per attempt.
    for (let i = 0; i < 200; i++) {
      manager.onWsData({
        type: "tunnel:ws-data",
        tunnelId: `dead-${i}`,
        data: "x".repeat(1024 * 1024 + 10), // poisons its tunnel immediately
        checkoutId: "main",
      });
    }
    manager.onWsData({
      type: "tunnel:ws-data",
      tunnelId: "live",
      data: "signalr-handshake",
      checkoutId: "main",
    });
    manager.onWsOpen({
      type: "tunnel:ws-open",
      tunnelId: "live",
      port: server.port!,
      scheme: "http",
      path: "/",
      checkoutId: "main",
    });

    await waitUntil(() => sent.some((m) => m.type === "tunnel:ws-data"));
    expect(sent.filter((m) => m.type === "tunnel:ws-data")).toMatchObject([
      { tunnelId: "live", data: "signalr-handshake" },
    ]);
  } finally {
    manager.stop();
    server.stop(true);
  }
});

test("stop() closes tunnels the app still believes are live", async () => {
  const server = startEchoServer();
  const { manager, sent } = makeManager();
  try {
    manager.onWsOpen({
      type: "tunnel:ws-open",
      tunnelId: "live",
      port: server.port!,
      scheme: "http",
      path: "/",
      checkoutId: "main",
    });
    // Deliberately NOT awaiting the upstream handshake: a session deleted
    // while a preview page is mid-connect is the case where the socket's own
    // close event never fires, so stop() has to send the frame itself.
    manager.stop();

    expect(sent.filter((m) => m.type === "tunnel:ws-close")).toMatchObject([
      { tunnelId: "live" },
    ]);
  } finally {
    server.stop(true);
  }
});
