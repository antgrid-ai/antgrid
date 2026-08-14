import { test, expect, afterEach } from "bun:test";
import { TunnelManager } from "../src/tunnel-manager";
import { createConnState } from "../src/conn-state";
import type { TunnelHttpRequest } from "../src/tunnel-protocol";

/** Upstream dev server that counts how many times it was actually reached —
 *  the whole point of the outbox is that a retry does NOT increment this. */
function startUpstream(opts: { body?: string; delayMs?: number } = {}) {
  let hits = 0;
  const server = Bun.serve({
    port: 0,
    async fetch() {
      hits += 1;
      if (opts.delayMs) await Bun.sleep(opts.delayMs);
      return new Response(opts.body ?? `hit-${hits}`, {
        headers: { "content-type": "text/plain" },
      });
    },
  });
  return { server, port: server.port!, hits: () => hits };
}

let stopServer: (() => void) | undefined;
afterEach(() => {
  stopServer?.();
  stopServer = undefined;
});

function makeManager() {
  const sent: Record<string, unknown>[] = [];
  const mgr = new TunnelManager({
    projectId: "proj",
    portLabels: new Map(),
    previewPorts: new Set(),
    sendTunnel: (data) => sent.push(data as Record<string, unknown>),
    sendEncrypted: () => {},
    relayHost: "relay.test",
    connState: createConnState(),
  });
  return { mgr, sent };
}

function request(port: number, requestId: string): TunnelHttpRequest {
  return {
    type: "tunnel:http-request",
    requestId,
    port,
    method: "GET",
    path: "/asset.js",
    checkoutId: "main",
  };
}

test("a retry with the same requestId replays the stored response and never re-fetches", async () => {
  const up = startUpstream();
  stopServer = () => up.server.stop(true);
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-1"));
  await mgr.onHttpRequest(request(up.port, "req-1"));

  expect(up.hits()).toBe(1);
  expect(sent).toHaveLength(2);
  expect(sent[0].body).toBe("hit-1");
  expect(sent[1]).toEqual(sent[0]);
});

test("a distinct requestId still reaches the dev server", async () => {
  const up = startUpstream();
  stopServer = () => up.server.stop(true);
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-1"));
  await mgr.onHttpRequest(request(up.port, "req-2"));

  expect(up.hits()).toBe(2);
  expect(sent[0].body).toBe("hit-1");
  expect(sent[1].body).toBe("hit-2");
});

// The app cannot see that its first request is still upstream, so a rate-limit
// retry can land mid-flight. Without the in-flight join this is a second fetch.
test("a retry arriving while the original is still upstream does not double-fetch", async () => {
  const up = startUpstream({ delayMs: 120 });
  stopServer = () => up.server.stop(true);
  const { mgr, sent } = makeManager();

  await Promise.all([
    mgr.onHttpRequest(request(up.port, "req-inflight")),
    mgr.onHttpRequest(request(up.port, "req-inflight")),
  ]);

  expect(up.hits()).toBe(1);
  expect(sent).toHaveLength(2);
  expect(sent[1]).toEqual(sent[0]);
});

// A 502 is a real answer to the request and must replay like any other — a
// retry that re-ran it would hit the same dead port and cost another timeout.
test("an upstream failure is replayed too, not retried into the dev server", async () => {
  const { mgr, sent } = makeManager();
  // Port 1 is privileged/unbound in test environments: the fetch fails fast.
  await mgr.onHttpRequest(request(1, "req-502"));
  await mgr.onHttpRequest(request(1, "req-502"));

  expect(sent).toHaveLength(2);
  expect(sent[0].status).toBe(502);
  expect(sent[1]).toEqual(sent[0]);
});

// Bodies past the per-entry cap are deliberately not retained, so this falls
// through to a fresh fetch rather than growing the outbox without bound.
test("a body over the retention cap is not stored and a retry re-fetches", async () => {
  const big = "x".repeat(3 * 1024 * 1024);
  const up = startUpstream({ body: big });
  stopServer = () => up.server.stop(true);
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-big"));
  await mgr.onHttpRequest(request(up.port, "req-big"));

  expect(up.hits()).toBe(2);
  expect(sent).toHaveLength(2);
});

test("stop() drops retained responses", async () => {
  const up = startUpstream();
  stopServer = () => up.server.stop(true);
  const { mgr, sent } = makeManager();

  await mgr.onHttpRequest(request(up.port, "req-1"));
  mgr.stop();
  await mgr.onHttpRequest(request(up.port, "req-1"));

  expect(up.hits()).toBe(2);
  expect(sent[1].body).toBe("hit-2");
});
