// PR#49 carry-over guards on the reconnect backoff, ported to the v3 client:
// `welcome` (not v2 `authenticated`) is the only reset point, and the schedule
// keeps equal jitter over a deterministic doubling curve.
import { test, expect, afterEach } from "bun:test";
import { RelayClient } from "../src/relay-client";
import vector from "../../evals/fixtures/relay-hello-vector.json";

let clients: RelayClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

function makeClient(url: string): RelayClient {
  // Real Ed25519 material: v3 signs `hello` on socket open, so fake keys
  // would throw inside sendHello before the backoff path is ever exercised.
  const client = new RelayClient({
    url,
    identity: {
      deviceId: vector.fields.deviceId,
      deviceName: "machine",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: vector.fields.publicKey,
      ed25519PrivateKey: Buffer.from(vector.ed25519.seedHex, "hex").toString("base64"),
    },
    generateKeypair: () => { throw new Error("not used"); },
    getLicenseToken: () => "tok",
    autoReconnect: false,
  });
  clients.push(client);
  return client;
}

/** Capture what scheduleReconnect hands setTimeout, without letting it fire. */
function captureSchedule<T>(fn: (calls: Array<{ cb: () => void; ms: number }>) => T): T {
  const calls: Array<{ cb: () => void; ms: number }> = [];
  const real = globalThis.setTimeout;
  // @ts-expect-error narrow test stub
  globalThis.setTimeout = (cb: () => void, ms: number) => { calls.push({ cb, ms }); return 0; };
  try {
    return fn(calls);
  } finally {
    globalThis.setTimeout = real;
  }
}

test("a `welcome` frame resets backoff", () => {
  const client = makeClient("ws://127.0.0.1:1");
  (client as any).backoff = 16_000;

  (client as any).handleTextMessage(
    JSON.stringify({ type: "welcome", deviceId: "dev", epoch: 1, serverTime: new Date().toISOString() }),
  );

  expect((client as any).backoff).toBe(1_000);
});

test("a socket that opens but never authenticates does NOT reset backoff", async () => {
  // The load-bearing case: backoff used to reset on socket `open`, before
  // auth had proven anything. A hello that keeps failing (a web outage
  // yielding LICENSE_UNAVAILABLE, say) then loops at ~1s forever —
  // open (reset) → hello fails → close → reconnect in 1s → repeat.
  const server = Bun.serve({
    port: 0,
    fetch: (req, srv) => (srv.upgrade(req) ? undefined : new Response("no")),
    websocket: { open: (ws) => ws.close(1008, "LICENSE_UNAVAILABLE"), message: () => {} },
  });

  try {
    const client = makeClient(`ws://127.0.0.1:${server.port}`);
    (client as any).backoff = 8_000;

    const disconnected = new Promise<void>((resolve) => {
      (client as any).opts.onDisconnected = resolve;
    });
    client.connect();
    await disconnected;

    expect((client as any).backoff).toBe(8_000);
  } finally {
    server.stop(true);
  }
});

test("each reconnect cycle doubles backoff up to the cap", () => {
  const client = makeClient("ws://127.0.0.1:1");
  (client as any).doConnect = () => {};

  const seen = captureSchedule((calls) => {
    const growth: number[] = [];
    for (let i = 0; i < 8; i++) {
      growth.push((client as any).backoff);
      (client as any).scheduleReconnect();
      calls.pop()!.cb();
    }
    return growth;
  });

  expect(seen).toEqual([1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]);
});

test("the scheduled delay is jittered into [backoff/2, backoff]", () => {
  const client = makeClient("ws://127.0.0.1:1");
  (client as any).backoff = 8_000;

  const delays = captureSchedule((calls) => {
    for (let i = 0; i < 50; i++) (client as any).scheduleReconnect();
    return calls.map((c) => c.ms);
  });

  expect(delays.every((ms) => ms >= 4_000 && ms <= 8_000)).toBe(true);
  // Equal jitter is the whole point — a deterministic delay would sync every
  // agent that lost the same relay into one reconnect wave.
  expect(new Set(delays).size).toBeGreaterThan(1);
});
