// SPDX-FileCopyrightText: 2026 Radha AI Products
// SPDX-License-Identifier: LicenseRef-Elastic-2.0

import { test, expect, afterEach } from "bun:test";
import {
  startServer,
  defaultConfig,
  connect,
  makeHello,
  makeFakeLicenseGate,
  decodeMessage,
  type RelayServer,
  type RelayServerDeps,
} from "./helpers/relay-harness.js";
import type { RelayConfig } from "../src/config.js";
import { setLogLevel } from "../src/logger.js";

type Frame = Record<string, unknown>;

const ACCOUNT_TOKEN = "bus-account";
const ACCOUNT_UID = `user-app-${ACCOUNT_TOKEN}`;

let relay: RelayServer | undefined;
const sockets: WebSocket[] = [];

afterEach(() => {
  for (const ws of sockets.splice(0)) ws.close();
  relay?.stop();
  relay = undefined;
  setLogLevel("error");
});

class Client {
  readonly frames: Frame[] = [];
  constructor(readonly ws: WebSocket, readonly deviceId: string) {
    ws.addEventListener("message", (e) => this.frames.push(decodeMessage((e as MessageEvent).data)));
  }

  of(type: string): Frame[] {
    return this.frames.filter((f) => f.type === type);
  }

  async waitFor(type: string, nth = 1): Promise<Frame> {
    const deadline = Date.now() + 2000;
    while (Date.now() < deadline) {
      const hit = this.of(type)[nth - 1];
      if (hit) return hit;
      await new Promise((r) => setTimeout(r, 5));
    }
    throw new Error(`no ${type} #${nth}; saw ${JSON.stringify(this.frames.map((f) => f.type))}`);
  }

  send(frame: Frame): void {
    this.ws.send(JSON.stringify(frame));
  }
}

async function join(
  r: RelayServer,
  deviceId: string,
  opts: { bus?: 1; deviceType?: "agent" | "app" } = {},
): Promise<Client> {
  const deviceType = opts.deviceType ?? "agent";
  const { hello } = await makeHello(r, { deviceId, deviceType, licenseToken: ACCOUNT_TOKEN, bus: opts.bus });
  const ws = await connect(r);
  sockets.push(ws);
  const client = new Client(ws, deviceId);
  ws.send(JSON.stringify(hello));
  await client.waitFor("welcome");
  return client;
}

function boot(config: Partial<RelayConfig> = {}, deps: RelayServerDeps = {}): RelayServer {
  const gate = makeFakeLicenseGate({ agentUid: () => ACCOUNT_UID });
  relay = startServer({ ...defaultConfig, ...config }, { licenseGate: gate, ...deps });
  return relay;
}

const uuid = (): string => crypto.randomUUID();
const EPK = "A".repeat(43) + "=";
const SIG = "A".repeat(86) + "==";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function send(to: string, id = uuid(), box = "Q".repeat(100)): Frame {
  return { type: "bus:send", id, to, blob: { epk: EPK, box }, ttlMs: 3_600_000 };
}

function ack(id: string, extra: Frame = {}): Frame {
  return { type: "bus:ack", id, outcome: "applied", sig: SIG, ...extra };
}

test("welcome carries bus:1 for agents and omits it for apps", async () => {
  boot();
  const agent = await join(relay!, uuid(), { bus: 1 });
  const app = await join(relay!, `${uuid()}#${uuid()}`, { deviceType: "app" });
  expect((await agent.waitFor("welcome")).bus).toBe(1);
  expect((await app.waitFor("welcome")).bus).toBeUndefined();
});

test("a live recipient gets bus:deliver and the sender a delivered-to-socket receipt", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  a.send(send(b.deviceId, id));

  const deliver = await b.waitFor("bus:deliver");
  expect(deliver).toMatchObject({ id, from: a.deviceId });
  expect(deliver.blob).toEqual({ epk: EPK, box: "Q".repeat(100) });
  expect(await a.waitFor("bus:receipt")).toEqual({
    type: "bus:receipt",
    id,
    to: b.deviceId,
    state: "delivered-to-socket",
  });
});

test("bus:ack forwards to the sender with the signature untouched and clears the entry", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  const sig = "Zm9v".repeat(21) + "Zm==";
  a.send(send(b.deviceId, id));
  await b.waitFor("bus:deliver");

  b.send(ack(id, { outcome: "refused", code: "NOT_ALLOWED_AGENT_REACH", sig }));
  expect(await a.waitFor("bus:acked")).toEqual({
    type: "bus:acked",
    id,
    to: b.deviceId,
    outcome: "refused",
    code: "NOT_ALLOWED_AGENT_REACH",
    sig,
  });
  expect(relay!.busQueue.stats().messages).toBe(0);
});

test("an ack for an entry the acker does not own is ignored", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const c = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  a.send(send(b.deviceId, id));
  await b.waitFor("bus:deliver");

  c.send(ack(id));
  await sleep(100);
  expect(a.of("bus:acked")).toEqual([]);
  expect(relay!.busQueue.stats().messages).toBe(1);
});

test("an app holding an offline agent's deviceId cannot ack that agent's mail", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const bId = uuid();
  const id = uuid();
  a.send(send(bId, id));
  await a.waitFor("bus:receipt");

  const app = await join(relay!, bId, { deviceType: "app", bus: 1 });
  app.send(ack(id));
  await sleep(100);
  expect(a.of("bus:acked")).toEqual([]);
  expect(relay!.busQueue.stats().messages).toBe(1);
});

test("a recipient this relay has never seen is queued, then flushed on its first hello", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const bId = uuid();
  const id = uuid();
  a.send(send(bId, id));
  expect(await a.waitFor("bus:receipt")).toMatchObject({ id, to: bId, state: "queued" });

  const b = await join(relay!, bId, { bus: 1 });
  expect(await b.waitFor("bus:deliver")).toMatchObject({ id, from: a.deviceId });
  expect(await a.waitFor("bus:receipt", 2)).toMatchObject({ id, state: "delivered-to-socket" });
});

test("the hello flush stops at the recipient's redelivery byte budget", async () => {
  // 144 bytes per entry against a 250 byte bucket: one flushes, the next waits.
  boot({ busSendBytesPerMin: 250 });
  const a = await join(relay!, uuid(), { bus: 1 });
  const c = await join(relay!, uuid(), { bus: 1 });
  const bId = uuid();
  a.send(send(bId));
  c.send(send(bId));
  await a.waitFor("bus:receipt");
  await c.waitFor("bus:receipt");

  const b = await join(relay!, bId, { bus: 1 });
  await b.waitFor("bus:deliver");
  await sleep(150);
  expect(b.of("bus:deliver")).toHaveLength(1);
  expect(relay!.busQueue.stats().messages).toBe(2);
});

test("a pre-bus agent is sent no bus frame and nothing is flushed to it", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const bId = uuid();
  a.send(send(bId));
  await a.waitFor("bus:receipt");

  const old = await join(relay!, bId);
  await sleep(100);
  expect(old.frames.filter((f) => String(f.type).startsWith("bus:"))).toEqual([]);
  expect(relay!.busQueue.stats().messages).toBe(1);

  old.send({ type: "bus:drain" });
  await sleep(100);
  expect(old.frames.filter((f) => String(f.type).startsWith("bus:"))).toEqual([]);
});

test("refuses not-agent for an app sender", async () => {
  boot();
  const app = await join(relay!, `${uuid()}#${uuid()}`, { deviceType: "app" });
  const to = uuid();
  const id = uuid();
  app.send(send(to, id));
  expect(await app.waitFor("bus:refused")).toEqual({ type: "bus:refused", id, to, reason: "not-agent", retryable: false });
  expect(relay!.busQueue.stats().messages).toBe(0);
});

test("refuses a send to self", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  a.send(send(a.deviceId, id));
  expect(await a.waitFor("bus:refused")).toEqual({
    type: "bus:refused",
    id,
    to: a.deviceId,
    reason: "self",
    retryable: false,
  });
});

test("refuses recipient-outdated for a live agent that did not opt in, and queues nothing", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const old = await join(relay!, uuid());
  const id = uuid();
  a.send(send(old.deviceId, id));
  expect(await a.waitFor("bus:refused")).toMatchObject({ id, reason: "recipient-outdated", retryable: true });
  expect(relay!.busQueue.stats().messages).toBe(0);
  await sleep(50);
  expect(old.frames.filter((f) => String(f.type).startsWith("bus:"))).toEqual([]);
});

test("refuses queue-full when a recipient is full and when a sender is full", async () => {
  boot({ busQueueMessagesPerDevice: 2, busQueueMessagesPerSender: 3 });
  const a = await join(relay!, uuid(), { bus: 1 });
  const target = uuid();
  a.send(send(target));
  a.send(send(target));
  const third = uuid();
  a.send(send(target, third));
  expect(await a.waitFor("bus:refused")).toMatchObject({ id: third, reason: "queue-full", retryable: true });

  a.send(send(uuid()));
  await a.waitFor("bus:receipt", 3);
  const fifth = uuid();
  a.send(send(uuid(), fifth));
  expect(await a.waitFor("bus:refused", 2)).toMatchObject({ id: fifth, reason: "queue-full", retryable: true });
});

test("refuses rate-limited once the sender's byte budget is spent", async () => {
  // One frame is 44 + 100 = 144 bytes: two fit in 300, the third does not.
  boot({ busSendBytesPerMin: 300 });
  const a = await join(relay!, uuid(), { bus: 1 });
  a.send(send(uuid()));
  a.send(send(uuid()));
  const third = uuid();
  a.send(send(uuid(), third));
  expect(await a.waitFor("bus:refused")).toMatchObject({ id: third, reason: "rate-limited", retryable: true });
  expect(a.of("bus:receipt")).toHaveLength(2);
});

test("sweep refuses expired to a live sender and drops the entry", async () => {
  const clock = { t: Date.now() };
  boot({}, { busNow: () => clock.t });
  const a = await join(relay!, uuid(), { bus: 1 });
  const to = uuid();
  const id = uuid();
  a.send({ ...send(to, id), ttlMs: 1_000 });
  await a.waitFor("bus:receipt");

  clock.t += 1_000;
  relay!.sweepBus();
  expect(await a.waitFor("bus:refused")).toEqual({ type: "bus:refused", id, to, reason: "expired", retryable: false });
  expect(relay!.busQueue.stats().messages).toBe(0);
});

test("a lost ack is recovered by the sweep while both ends stay connected", async () => {
  const clock = { t: Date.now() };
  let drop = true;
  boot({}, { busNow: () => clock.t, busFaults: { dropAck: () => {
    const armed = drop;
    drop = false;
    return armed;
  } } });
  const a = await join(relay!, uuid(), { bus: 1 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  const sig = "Zm9v".repeat(21) + "Zm==";
  a.send(send(b.deviceId, id));
  await b.waitFor("bus:deliver");

  b.send(ack(id, { sig }));
  await sleep(100);
  expect(a.of("bus:acked")).toEqual([]);
  expect(relay!.busQueue.stats().messages).toBe(1);

  relay!.sweepBus();
  await sleep(50);
  expect(b.of("bus:deliver")).toHaveLength(1);

  clock.t += 60_000;
  relay!.sweepBus();
  await b.waitFor("bus:deliver", 2);
  b.send(ack(id, { sig }));
  expect(await a.waitFor("bus:acked")).toMatchObject({ id, sig, outcome: "applied" });
});

test("a duplicate bus:send redelivers only once the redelivery interval has passed", async () => {
  const clock = { t: Date.now() };
  boot({}, { busNow: () => clock.t });
  const a = await join(relay!, uuid(), { bus: 1 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  a.send(send(b.deviceId, id));
  await b.waitFor("bus:deliver");

  a.send(send(b.deviceId, id));
  await a.waitFor("bus:receipt", 2);
  expect(a.of("bus:receipt")[1]).toMatchObject({ id, state: "delivered-to-socket" });
  expect(b.of("bus:deliver")).toHaveLength(1);

  clock.t += 60_000;
  a.send(send(b.deviceId, id));
  await b.waitFor("bus:deliver", 2);
  b.send(ack(id));
  expect(await a.waitFor("bus:acked")).toMatchObject({ id, outcome: "applied" });
  expect(relay!.busQueue.stats().messages).toBe(0);
});

test("a duplicate for an offline recipient answers queued and holds one entry", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const id = uuid();
  const to = uuid();
  a.send(send(to, id));
  a.send(send(to, id));
  await a.waitFor("bus:receipt", 2);
  expect(a.of("bus:receipt").map((f) => f.state)).toEqual(["queued", "queued"]);
  expect(relay!.busQueue.stats().messages).toBe(1);
});

test("bus:drain re-sends the pending queue, and a second drain within the interval is ignored", async () => {
  boot();
  const a = await join(relay!, uuid(), { bus: 1 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const ids = [uuid(), uuid()];
  for (const id of ids) a.send(send(b.deviceId, id));
  await b.waitFor("bus:deliver", 2);

  b.send({ type: "bus:drain" });
  await b.waitFor("bus:deliver", 4);
  expect(b.of("bus:deliver").slice(2).map((f) => f.id)).toEqual(ids);

  b.send({ type: "bus:drain" });
  await sleep(150);
  expect(b.of("bus:deliver")).toHaveLength(4);
});

test("bus:drain stops at the recipient's redelivery byte budget", async () => {
  // 144 bytes per entry against a 250 byte bucket: one resend fits, the next does not.
  boot({ busSendBytesPerMin: 250 });
  const b = await join(relay!, uuid(), { bus: 1 });
  const a = await join(relay!, uuid(), { bus: 1 });
  const c = await join(relay!, uuid(), { bus: 1 });
  a.send(send(b.deviceId));
  c.send(send(b.deviceId));
  await b.waitFor("bus:deliver", 2);

  b.send({ type: "bus:drain" });
  await b.waitFor("bus:deliver", 3);
  await sleep(150);
  expect(b.of("bus:deliver")).toHaveLength(3);
});

test("an ack is never forwarded to a same-deviceId socket under another account", async () => {
  const aId = uuid();
  const bId = uuid();
  let aMoved = false;
  const gate = makeFakeLicenseGate({ agentUid: (d) => (d === aId && aMoved ? "user-other" : ACCOUNT_UID) });
  relay = startServer(defaultConfig, { licenseGate: gate });

  const a = await join(relay, aId, { bus: 1 });
  a.send(send(bId));
  await a.waitFor("bus:receipt");
  a.ws.close();
  await sleep(50);

  // aId now belongs to a different account: it must not receive the original sender's ack.
  aMoved = true;
  const impostor = await join(relay, aId, { bus: 1 });
  const b = await join(relay, bId, { bus: 1 });
  const deliver = await b.waitFor("bus:deliver");
  b.send(ack(String(deliver.id)));
  await sleep(150);
  expect(impostor.of("bus:acked")).toEqual([]);
  expect(impostor.of("bus:receipt")).toEqual([]);
});

test("a same-deviceId recipient under another account is never a target", async () => {
  const xId = uuid();
  const gate = makeFakeLicenseGate({ agentUid: (d) => (d === xId ? "user-other" : ACCOUNT_UID) });
  relay = startServer(defaultConfig, { licenseGate: gate });

  const a = await join(relay, uuid(), { bus: 1 });
  const stranger = await join(relay, xId, { bus: 1 });
  a.send(send(xId));
  expect(await a.waitFor("bus:receipt")).toMatchObject({ state: "queued" });
  await sleep(100);
  expect(stranger.of("bus:deliver")).toEqual([]);
  expect(stranger.of("bus:refused")).toEqual([]);
});

test("logs carry outcomes and counts, never blob content or the account id", async () => {
  const lines: string[] = [];
  const original = console.log;
  console.log = (...args: unknown[]) => {
    lines.push(args.map(String).join(" "));
  };
  try {
    boot({ logLevel: "debug" });
    const a = await join(relay!, uuid(), { bus: 1 });
    const b = await join(relay!, uuid(), { bus: 1 });
    const secret = "SECRETBLOBCONTENT".repeat(4);
    const id = uuid();
    a.send(send(b.deviceId, id, secret));
    await b.waitFor("bus:deliver");
    b.send(ack(id));
    await a.waitFor("bus:acked");
    a.send(send(a.deviceId));
    await a.waitFor("bus:refused");
  } finally {
    console.log = original;
  }
  const joined = lines.join("\n");
  expect(joined).toContain("bus delivered");
  expect(joined).not.toContain("SECRETBLOBCONTENT");
  expect(joined).not.toContain('"box"');
  expect(joined).not.toContain(EPK);
  expect(joined).not.toContain(ACCOUNT_UID);
});
