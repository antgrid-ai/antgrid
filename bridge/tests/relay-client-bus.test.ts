// The central client carries opaque bus frames and nothing more: it asks for
// them in the hello, learns from the welcome whether the relay will send them,
// and hands each one to a callback without reading the blob.
import { afterEach, expect, test } from "bun:test";
import { randomUUID } from "node:crypto";
import { CentralControlClient } from "../src/central-control-client";
import { netwatch } from "../src/netwatch";
import vector from "../../evals/fixtures/relay-hello-vector.json";

const clients: CentralControlClient[] = [];
afterEach(() => { for (const c of clients.splice(0)) try { c.close(); } catch {} });

function makeClient(onBus?: (m: unknown) => void) {
  const seed = Buffer.from(vector.ed25519.seedHex, "hex").toString("base64");
  const sent: string[] = [];
  const client = new CentralControlClient({
    url: "ws://relay.antgrid.ai:8443/ws",
    identity: {
      deviceId: vector.fields.deviceId,
      deviceName: "agent",
      createdAt: new Date().toISOString(),
      ed25519PublicKey: vector.fields.publicKey,
      ed25519PrivateKey: seed,
    },
    getLicenseToken: () => vector.fields.licenseToken,
    onBus,
  });
  clients.push(client);
  let closed = 0;
  (client as any).ws = { readyState: WebSocket.OPEN, send: (d: string) => sent.push(d), close: () => { closed++; } };
  return { client, sent, closes: () => closed };
}

const welcome = (bus?: 1) => JSON.stringify({ type: "welcome", deviceId: vector.fields.deviceId, epoch: 1, serverTime: new Date().toISOString(), ...(bus ? { bus } : {}) });

const SIG = "A".repeat(86) + "==";
const blob = { epk: Buffer.alloc(32, 7).toString("base64"), box: Buffer.alloc(60, 9).toString("base64") };
const frames = {
  receipt: { type: "bus:receipt", id: randomUUID(), to: randomUUID(), state: "queued" },
  deliver: { type: "bus:deliver", id: randomUUID(), from: randomUUID(), blob },
  acked: { type: "bus:acked", id: randomUUID(), to: randomUUID(), outcome: "refused", code: "NO_SESSION", sig: SIG },
  refused: { type: "bus:refused", id: randomUUID(), to: randomUUID(), reason: "queue-full", retryable: true },
};

test("the agent hello asks for bus frames", async () => {
  const { client, sent } = makeClient();
  await client.sendHello();
  expect(JSON.parse(sent[0]!).bus).toBe(1);
});

test("sendBus is false before welcome, false after a welcome without bus, true after welcome with bus", () => {
  const { client, sent } = makeClient();
  const frame = { type: "bus:drain" } as const;
  expect(client.busLinkState()).toBe("offline");
  expect(client.sendBus(frame)).toBe(false);

  client.handleTextMessage(welcome());
  expect(client.busLinkState()).toBe("unsupported");
  expect(client.sendBus(frame)).toBe(false);
  expect(sent).toHaveLength(0);

  client.handleTextMessage(welcome(1));
  expect(client.busLinkState()).toBe("ready");
  expect(client.sendBus(frame)).toBe(true);
  expect(JSON.parse(sent[0]!)).toEqual(frame);
});

test("support does not survive a reconnect", () => {
  const { client } = makeClient();
  client.handleTextMessage(welcome(1));
  expect(client.busLinkState()).toBe("ready");
  client.doConnect();
  expect(client.busLinkState()).toBe("offline");
});

test("each of the four server frames reaches onBus", () => {
  const got: unknown[] = [];
  const { client } = makeClient((m) => got.push(m));
  client.handleTextMessage(welcome(1));
  for (const f of Object.values(frames)) client.handleTextMessage(JSON.stringify(f));
  expect(got).toEqual(Object.values(frames));
});

test("a malformed bus frame is dropped without closing the socket", () => {
  const got: unknown[] = [];
  const { client, closes } = makeClient((m) => got.push(m));
  client.handleTextMessage(welcome(1));
  client.handleTextMessage(JSON.stringify({ ...frames.deliver, blob: { epk: "x", box: "y" } }));
  client.handleTextMessage(JSON.stringify({ ...frames.acked, code: undefined }));
  expect(got).toHaveLength(0);
  expect(closes()).toBe(0);
});

test("netwatch keeps the outcome of a bus frame and none of its id, peer or blob", () => {
  const records: Array<Record<string, unknown>> = [];
  const real = netwatch.record.bind(netwatch);
  (netwatch as any).record = (r: Record<string, unknown>) => { records.push(r); };
  try {
    const { client } = makeClient();
    client.handleTextMessage(welcome(1));
    for (const f of Object.values(frames)) client.handleTextMessage(JSON.stringify(f));
    client.sendBus({ type: "bus:send", id: randomUUID(), to: randomUUID(), blob, ttlMs: 1000 });
  } finally {
    (netwatch as any).record = real;
  }
  const bus = records.filter((r) => String(r.msgType ?? "").startsWith("bus:"));
  expect(bus.length).toBe(5);
  const text = JSON.stringify(bus);
  for (const f of Object.values(frames)) {
    expect(text).not.toContain(f.id);
    expect(text).not.toContain(blob.box);
    expect(text).not.toContain(blob.epk);
    if ("to" in f) expect(text).not.toContain(f.to);
    if ("from" in f) expect(text).not.toContain(f.from);
  }
  expect(bus.find((r) => r.msgType === "bus:acked")?.detail).toEqual({ code: "NO_SESSION", outcome: "refused" });
  expect(bus.find((r) => r.msgType === "bus:receipt")?.detail).toEqual({ state: "queued" });
});
