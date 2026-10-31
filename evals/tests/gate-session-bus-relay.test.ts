import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { allocatePort, startRelay, type RelayHandle } from "../helpers/harness";
import { CentralTestClient } from "../helpers/central-test-client";
import { generateEphemeralKeypair } from "../../bridge/src/key-exchange";
import {
  openBus,
  sealBus,
  signBusAck,
  verifyBusAck,
  type InnerHeader,
} from "../../bridge/src/session-bus/seal";

/** Relay-only bus rows: two raw agents and an app speak sealed bus frames
 *  through a real relay. The relay never holds a bus key, so every open here
 *  is done by the recipient side of the test. */
describe("gate: session bus relay carrier", () => {
  let relay: RelayHandle;
  const open: CentralTestClient[] = [];

  beforeAll(async () => {
    relay = await startRelay({ port: allocatePort() });
  });

  // The relay caps connections per IP, so each row releases its sockets.
  afterEach(async () => {
    for (const client of open.splice(0)) await client.disconnect();
  });

  afterAll(() => {
    relay.stop();
  });

  interface Party {
    client: CentralTestClient;
    id: string;
    edPub: string;
    edSeed: string;
    busPub: string;
    busPriv: string;
  }

  function busKeys() {
    const k = generateEphemeralKeypair();
    return { busPub: k.publicKey.toString("base64"), busPriv: k.privateKey.toString("base64") };
  }

  async function agent(name: string, opts: { deviceId?: string; keys?: ReturnType<typeof busKeys>; identity?: any } = {}): Promise<Party> {
    const client = await CentralTestClient.connectAndAuth(relay.url, {
      deviceType: "agent",
      name,
      bus: true,
      deviceId: opts.deviceId,
      identity: opts.identity,
    });
    open.push(client);
    const identity = client.exportIdentity();
    return {
      client,
      id: client.deviceId,
      edPub: identity.publicKeyBase64,
      edSeed: identity.privateKeySeed.toString("base64"),
      ...(opts.keys ?? busKeys()),
    };
  }

  function header(from: Party, to: string): InnerHeader {
    const now = Date.now();
    return {
      v: 1, from: from.id, to, id: crypto.randomUUID(), role: "agent", kind: "message",
      sentAt: now, expiresAt: now + 60_000,
    };
  }

  function sealFor(from: Party, toId: string, toBusPub: string, body: string) {
    const h = header(from, toId);
    const sealed = sealBus({ header: h, body, signSeedB64: from.edSeed, recipientBusPubB64: toBusPub });
    if (!sealed.ok) throw new Error(`seal refused: ${sealed.code}`);
    return { h, blob: sealed.blob };
  }

  const isBus = (m: any) => typeof m?.type === "string" && m.type.startsWith("bus:");

  test("live delivery: B opens the blob and its signed ack verifies at A", async () => {
    const a = await agent("bus-a");
    const b = await agent("bus-b");
    const { h, blob } = sealFor(a, b.id, b.busPub, "hello from A");

    a.client.sendRaw({ type: "bus:send", id: h.id, to: b.id, blob, ttlMs: 60_000 });
    const deliver = await b.client.waitFor((m) => m.type === "bus:deliver" && m.id === h.id);
    expect(deliver.from).toBe(a.id);
    expect(await a.client.waitFor((m) => m.type === "bus:receipt" && m.id === h.id && m.state === "delivered-to-socket"))
      .toMatchObject({ to: b.id });

    const opened = openBus({
      blob: deliver.blob, from: a.id, to: b.id, id: h.id,
      ownBusPrivB64: b.busPriv, ownBusPubB64: b.busPub, senderEd25519PubB64: a.edPub,
    });
    expect(opened.ok).toBe(true);
    if (opened.ok) expect(opened.body).toBe("hello from A");

    const fields = { from: a.id, to: b.id, id: h.id, outcome: "applied" as const };
    b.client.sendRaw({ type: "bus:ack", id: h.id, outcome: "applied", sig: signBusAck(b.edSeed, fields) });
    const acked = await a.client.waitFor((m) => m.type === "bus:acked" && m.id === h.id);
    expect(acked).toMatchObject({ to: b.id, outcome: "applied" });
    expect(verifyBusAck(b.edPub, fields, acked.sig)).toBe(true);
    expect(relay.busStats().messages).toBe(0);
  }, 15_000);

  test("offline recipient: A is told queued, B receives it on connecting", async () => {
    const a = await agent("bus-a2");
    const bId = crypto.randomUUID();
    const bKeys = busKeys();
    const { h, blob } = sealFor(a, bId, bKeys.busPub, "held for B");

    a.client.sendRaw({ type: "bus:send", id: h.id, to: bId, blob, ttlMs: 60_000 });
    expect(await a.client.waitFor((m) => m.type === "bus:receipt" && m.id === h.id))
      .toMatchObject({ state: "queued", to: bId });
    expect(relay.busStats().messages).toBe(1);

    const b = await agent("bus-b2", { deviceId: bId, keys: bKeys });
    const deliver = await b.client.waitFor((m) => m.type === "bus:deliver" && m.id === h.id);
    const opened = openBus({
      blob: deliver.blob, from: a.id, to: bId, id: h.id,
      ownBusPrivB64: b.busPriv, ownBusPubB64: b.busPub, senderEd25519PubB64: a.edPub,
    });
    expect(opened.ok && opened.body).toBe("held for B");

    const fields = { from: a.id, to: bId, id: h.id, outcome: "applied" as const };
    b.client.sendRaw({ type: "bus:ack", id: h.id, outcome: "applied", sig: signBusAck(b.edSeed, fields) });
    await a.client.waitFor((m) => m.type === "bus:acked" && m.id === h.id);
    expect(relay.busStats().messages).toBe(0);
  }, 15_000);

  test("a re-addressed blob does not open", async () => {
    const a = await agent("bus-a3");
    const b = await agent("bus-b3");
    const { h, blob } = sealFor(a, b.id, b.busPub, "for B only");

    const wrongRecipient = crypto.randomUUID();
    const wrongId = crypto.randomUUID();
    const base = { blob, ownBusPrivB64: b.busPriv, ownBusPubB64: b.busPub, senderEd25519PubB64: a.edPub };
    expect(openBus({ ...base, from: a.id, to: wrongRecipient, id: h.id }).ok).toBe(false);
    expect(openBus({ ...base, from: a.id, to: b.id, id: wrongId }).ok).toBe(false);
    expect(openBus({ ...base, from: b.id, to: b.id, id: h.id }).ok).toBe(false);
    expect(openBus({ ...base, from: a.id, to: b.id, id: h.id }).ok).toBe(true);
  });

  test("an app sending bus:send is refused not-agent", async () => {
    const b = await agent("bus-b4");
    const app = await CentralTestClient.connectAndAuth(relay.url, { deviceType: "app", name: "bus-app" });
    open.push(app);
    const a = await agent("bus-a4");
    const { h, blob } = sealFor(a, b.id, b.busPub, "from an app");

    app.sendRaw({ type: "bus:send", id: h.id, to: b.id, blob, ttlMs: 60_000 });
    expect(await app.waitFor((m) => m.type === "bus:refused" && m.id === h.id))
      .toMatchObject({ reason: "not-agent", retryable: false });
    await expect(b.client.waitFor(isBus, 400)).rejects.toThrow();
  }, 15_000);

  test("an app is never delivered a bus frame, even one that asks for them", async () => {
    const app = await CentralTestClient.connectAndAuth(relay.url, { deviceType: "app", name: "bus-app2", bus: true });
    open.push(app);
    const a = await agent("bus-a5");
    const b = await agent("bus-b5");
    const { h, blob } = sealFor(a, b.id, b.busPub, "not for apps");

    a.client.sendRaw({ type: "bus:send", id: h.id, to: b.id, blob, ttlMs: 60_000 });
    await b.client.waitFor((m) => m.type === "bus:deliver" && m.id === h.id);
    app.sendRaw({ type: "bus:drain" });
    await expect(app.waitFor(isBus, 500)).rejects.toThrow();
  }, 15_000);
});
