import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { allocatePort, setMobileAccess, startRelay, type RelayHandle } from "../helpers/harness";
import { setupRelayBusEnv, startSinkSession, type RelayBusEnv, type RelayBusMachine } from "../helpers/relay-bus-env";
import {
  authorityGrants, busCall, localVerb, lowerGrants, persistedSessions, setAgentReach, untilAsync,
} from "../support/session-bus";
import { createMessage } from "../../bridge/src/protocol";
import { NO_PROGRESS_EXCHANGES } from "../../bridge/src/session-bus/constants";
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

// Long enough for two bridges, their PTY trees and a shared relay to come up.
const ROW_TIMEOUT_MS = 240_000;
const CROSS_TIMEOUT_MS = 30_000;
const DIRECTORY_TIMEOUT_MS = 60_000;

describe("gate: session bus relay, two bridges", () => {
  let env: RelayBusEnv | undefined;
  let tmp: string | undefined;

  afterEach(async () => {
    await env?.teardown();
    env = undefined;
    // Tolerated: a PTY may still hold its sink open briefly after teardown.
    if (tmp) try { rmSync(tmp, { recursive: true, force: true }); } catch { /* the PTY still has it */ }
    tmp = undefined;
  });

  async function boot(): Promise<RelayBusEnv> {
    tmp = mkdtempSync(join(tmpdir(), "antgrid-relay-bus-"));
    env = await setupRelayBusEnv({ tmp });
    await env.waitForBusKeys();
    return env;
  }

  const addressOf = (m: RelayBusMachine, sessionId: string) =>
    ({ machineId: m.machineId, projectId: m.projectId, sessionId });

  async function thread(m: RelayBusMachine, sessionId: string, threadId: string): Promise<any[]> {
    const res = await busCall(m.abDir, "thread", { terminalId: sessionId, query: { threadId } });
    return res.status === 200 ? res.body.entries ?? [] : [];
  }

  async function awaitOut(
    m: RelayBusMachine, sessionId: string, threadId: string, what: string,
    pred: (e: any) => boolean, timeoutMs = CROSS_TIMEOUT_MS,
  ): Promise<any> {
    return untilAsync(async () => {
      return (await thread(m, sessionId, threadId)).find((e) => e.direction === "out" && pred(e));
    }, timeoutMs, what);
  }

  async function mailbox(m: RelayBusMachine, sessionId: string): Promise<any> {
    const res = await busCall(m.abDir, "inbox", { terminalId: sessionId });
    expect(res.status).toBe(200);
    return res.body;
  }

  /** Reading marks read, so every poll's posts are accumulated: a duplicate
   *  delivery shows up as a second element rather than being lost. */
  async function awaitPosts(m: RelayBusMachine, sessionId: string, timeoutMs = CROSS_TIMEOUT_MS): Promise<any[]> {
    const posts: any[] = [];
    await untilAsync(async () => {
      const res = await busCall(m.abDir, "inbox", { terminalId: sessionId });
      if (res.status === 200) posts.push(...(res.body.posts ?? []));
      return posts.length > 0 ? true : undefined;
    }, timeoutMs, `a post in session ${sessionId}'s mailbox on machine ${m.name}`);
    return posts;
  }

  async function post(m: RelayBusMachine, from: string, body: object) {
    return busCall(m.abDir, "post", { terminalId: from, body });
  }

  /** The row a send needs in A's mirror arrives by A's own refresh over the
   *  relay; waiting on it is the only way a test can have one. */
  async function seedPeerRow(a: RelayBusMachine, sa: string, b: RelayBusMachine, sb: string): Promise<void> {
    let last = "";
    try {
      await untilAsync(async () => {
        const res = await busCall(a.abDir, "sessions", { terminalId: sa });
        last = `${res.status} ${JSON.stringify(res.body.reach ?? res.body)}`;
        return res.status === 200 && (res.body.sessions ?? []).some((r: any) => r.sessionId === sb) ? true : undefined;
      }, DIRECTORY_TIMEOUT_MS, "B's session to appear in A's directory");
    } catch (err) {
      throw new Error(`${(err as Error).message}; last read: ${last}`);
    }
  }

  test("with no app, A lists B's session within a minute and B's reach switch is reported", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    const listed = await busCall(a.abDir, "sessions", { terminalId: sa });
    const row = listed.body.sessions.find((r: any) => r.sessionId === sb);
    expect(row.machineId).toBe(b.machineId);
    expect(row.title).toBe("beta");
    expect(typeof row.asOf).toBe("number");
    expect(listed.body.reach.scope).toBe("network");

    await setAgentReach(b.abDir, false);
    const refused = await untilAsync(async () => {
      const res = await busCall(a.abDir, "sessions", { terminalId: sa });
      const m = res.body?.reach?.machines?.find((x: any) => x.machineId === b.machineId);
      return m?.status === "reach-refused" ? res.body : undefined;
    }, DIRECTORY_TIMEOUT_MS, "A's reach line to show B as reach-refused");
    expect((refused.sessions ?? []).some((r: any) => r.machineId === b.machineId)).toBe(false);
  }, ROW_TIMEOUT_MS + DIRECTORY_TIMEOUT_MS);

  test("a post crosses A to B and A's thread shows it delivered", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    const sent = await post(a, sa, { to: addressOf(b, sb), summary: "crosses", text: "hello across" });
    expect(`${sent.status} ${JSON.stringify(sent.body)}`).toMatch(/^200 /);
    expect(sent.body.ok).toBe(true);
    const posts = await awaitPosts(b, sb);
    expect(posts).toHaveLength(1);
    expect(posts[0].summary).toBe("crosses");
    expect(posts[0].from.machineId).toBe(a.machineId);
    const entry = await awaitOut(a, sa, sent.body.threadId, "A's entry to read delivered", (e) => e.delivery === "delivered");
    expect(entry.peer.machineId).toBe(b.machineId);
  }, ROW_TIMEOUT_MS);

  test("a post to a killed machine is held or relayed, lands exactly once after restart, and A shows delivered", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    // The session list flushes behind the verb; a kill before it lands loses the
    // session the post is addressed to.
    await untilAsync(async () => (persistedSessions(b.abDir, b.projectId).some((s) => s.id === sb) ? true : undefined), 15_000, "B to persist its session");
    await b.kill();
    const sent = await post(a, sa, { to: addressOf(b, sb), summary: "while down", text: "queued for B" });
    expect(`${sent.status} ${JSON.stringify(sent.body)}`).toMatch(/^200 /);
    expect(["relayed", "held"]).toContain(sent.body.rung);
    await b.restart();
    // The flush can land while B is still hydrating its sessions.
    const posts = await awaitPosts(b, sb, 90_000);
    expect(posts).toHaveLength(1);
    expect(posts[0].summary).toBe("while down");
    await awaitOut(a, sa, sent.body.threadId, "A's entry to read delivered", (e) => e.delivery === "delivered", 90_000);
    expect((await mailbox(b, sb)).posts).toHaveLength(0);
  }, ROW_TIMEOUT_MS);

  test("a dropped ack with both bridges running redelivers, applies once, and A flips to delivered", async () => {
    const { a, b, relay } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    relay.dropNextBusAck();
    const sent = await post(a, sa, { to: addressOf(b, sb), summary: "ack lost", text: "once only" });
    expect(`${sent.status} ${JSON.stringify(sent.body)}`).toMatch(/^200 /);
    const posts = await awaitPosts(b, sb);
    expect(posts).toHaveLength(1);
    await awaitOut(a, sa, sent.body.threadId, "A's entry to read delivered after the redelivery", (e) => e.delivery === "delivered", 120_000);
    const again = await mailbox(b, sb);
    expect(again.posts).toHaveLength(0);
    expect(again.dropped).toBe(0);
  }, ROW_TIMEOUT_MS);

  test("remote access off on A refuses the send up front", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    await setMobileAccess(a.abDir, false);
    const sent = await post(a, sa, { to: addressOf(b, sb), summary: "nope", text: "nope" });
    expect(sent.status).toBe(403);
    expect(sent.body.code).toBe("REMOTE_ACCESS_OFF");
  }, ROW_TIMEOUT_MS);

  test("remote access off on B shows A a refused thread entry", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    await setMobileAccess(b.abDir, false);
    const sent = await post(a, sa, { to: addressOf(b, sb), summary: "refused", text: "refused" });
    expect(`${sent.status} ${JSON.stringify(sent.body)}`).toMatch(/^200 /);
    const entry = await awaitOut(a, sa, sent.body.threadId, "A's entry to read refused", (e) => e.delivery === "refused");
    expect(entry.refusedCode).toBe("REMOTE_ACCESS_OFF");
    expect((await mailbox(b, sb)).posts).toHaveLength(0);
  }, ROW_TIMEOUT_MS);

  test("B replies on the thread and A receives it", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    const sent = await post(a, sa, { to: addressOf(b, sb), summary: "question", text: "which one?" });
    const threadId = sent.body.threadId as string;
    await awaitPosts(b, sb);
    const replied = await busCall(b.abDir, "reply", {
      terminalId: sb,
      body: { threadId, summary: "answer", text: "the second" },
    });
    expect(replied.status).toBe(200);
    expect(replied.body.ok).toBe(true);
    const inbound = await untilAsync(async () => {
      const entries = await thread(a, sa, threadId);
      return entries.find((e) => e.direction === "in" && e.summary === "answer");
    }, CROSS_TIMEOUT_MS, "B's reply to appear on A's thread");
    expect(inbound.peer.machineId).toBe(b.machineId);
  }, ROW_TIMEOUT_MS);

  test("the pair budget crosses the relay and halts with NO_PROGRESS", async () => {
    const { a, b } = await boot();
    const sa = await startSinkSession(a, "alpha");
    const sb = await startSinkSession(b, "beta");
    await seedPeerRow(a, sa, b, sb);
    const opener = await post(a, sa, { to: addressOf(b, sb), summary: "round 0", text: "round 0" });
    expect(opener.status).toBe(200);
    const threadId = opener.body.threadId as string;
    for (let i = 1; i < NO_PROGRESS_EXCHANGES; i++) {
      const sent = await post(a, sa, { threadId, summary: `round ${i}`, text: `round ${i}` });
      expect(`${sent.status} ${JSON.stringify(sent.body)}`).toMatch(/^200 /);
    }
    const halted = await post(a, sa, { to: addressOf(b, sb), summary: "round again", text: "round again" });
    expect(halted.status).toBe(429);
    expect(halted.body.code).toBe("NO_PROGRESS");
  }, ROW_TIMEOUT_MS);
});

// The bridge's directory refreshes about every 20 s and on kicks, so a grant
// change reaches the other machine inside this bound.
const GRANT_TIMEOUT_MS = 45_000;

describe("gate: session bus relay, orchestration", () => {
  let env: RelayBusEnv | undefined;
  let tmp: string | undefined;

  afterEach(async () => {
    await env?.teardown();
    env = undefined;
    if (tmp) try { rmSync(tmp, { recursive: true, force: true }); } catch { /* the PTY still has it */ }
    tmp = undefined;
  });

  async function boot(): Promise<RelayBusEnv & { sa: string }> {
    tmp = mkdtempSync(join(tmpdir(), "antgrid-relay-orch-"));
    env = await setupRelayBusEnv({ tmp });
    await env.waitForBusKeys();
    return Object.assign(env, { sa: await startSinkSession(env.a, "alpha") });
  }

  function request(a: RelayBusMachine, sa: string, b: RelayBusMachine, method: string, params: object) {
    return busCall(a.abDir, "request", { terminalId: sa, body: { to: b.machineId, method, params, timeoutMs: 20_000 } });
  }

  /** Repeats a request until its answer satisfies `done`, which is how a test
   *  waits out the directory refresh without a hook into it. */
  async function requestUntil(
    a: RelayBusMachine, sa: string, b: RelayBusMachine, method: string, params: object,
    done: (res: { status: number; body: any }) => boolean, what: string,
  ) {
    let last = "";
    try {
      return await untilAsync(async () => {
        const res = await request(a, sa, b, method, params);
        last = `${res.status} ${JSON.stringify(res.body)}`;
        return done(res) ? res : undefined;
      }, GRANT_TIMEOUT_MS, what);
    } catch (err) {
      throw new Error(`${(err as Error).message}; last answer: ${last}`);
    }
  }

  const ok = (res: { body: any }) => res.body?.ok === true;
  const refusedWith = (code: string) => (res: { status: number; body: any }) => res.status === 403 && res.body?.code === code;

  async function reachControl(e: RelayBusEnv, sa: string): Promise<void> {
    e.license.setOrchestrator(e.a.machineId, true);
    e.license.setBusControl(e.b.machineId, true);
    await requestUntil(e.a, sa, e.b, "project.start", { projectId: e.b.projectId }, ok, "A's project.start to be allowed on B");
  }

  test("a granted orchestrator creates and starts a session on a control machine", async () => {
    const e = await boot();
    await reachControl(e, e.sa);
    const created = await request(e.a, e.sa, e.b, "session.create", { projectId: e.b.projectId, name: "driven" });
    expect(`${created.status} ${JSON.stringify(created.body)}`).toMatch(/^200 /);
    const sessionId = created.body.result.session.id as string;
    // No initialPrompt: the sink guest is a generic agent, which cannot take an
    // opening prompt through its terminal invocation.
    const started = await request(e.a, e.sa, e.b, "session.start", { projectId: e.b.projectId, sessionId });
    expect(`${started.status} ${JSON.stringify(started.body)}`).toMatch(/^200 /);
    const listed = await requestUntil(e.a, e.sa, e.b, "sessions.list", { projectId: e.b.projectId }, (res) =>
      (res.body?.result?.sessions ?? []).some((r: any) => r.id === sessionId && r.running === true),
      "B to list the driven session as running");
    expect(listed.body.result.sessions.find((r: any) => r.id === sessionId).name).toBe("driven");
  }, ROW_TIMEOUT_MS + GRANT_TIMEOUT_MS * 2);

  test("a machine without the busControl grant refuses control requests", async () => {
    const e = await boot();
    e.license.setOrchestrator(e.a.machineId, true);
    await requestUntil(e.a, e.sa, e.b, "sessions.list", { projectId: e.b.projectId }, ok, "A's read request to be allowed on B");
    const res = await request(e.a, e.sa, e.b, "project.start", { projectId: e.b.projectId });
    expect(res.status).toBe(403);
    expect(res.body.code).toBe("NOT_ALLOWED_AGENT_REACH");
  }, ROW_TIMEOUT_MS + GRANT_TIMEOUT_MS);

  test("local reach off wins over a busControl grant", async () => {
    const e = await boot();
    await reachControl(e, e.sa);
    await setAgentReach(e.b.abDir, false);
    const res = await requestUntil(e.a, e.sa, e.b, "project.start", { projectId: e.b.projectId },
      refusedWith("NOT_ALLOWED_AGENT_REACH"), "B's local off to refuse control");
    expect(res.body.code).toBe("NOT_ALLOWED_AGENT_REACH");
  }, ROW_TIMEOUT_MS + GRANT_TIMEOUT_MS * 2);

  test("a machine that is not an orchestrator is refused NOT_ORCHESTRATOR", async () => {
    const e = await boot();
    e.license.setBusControl(e.b.machineId, true);
    const res = await requestUntil(e.a, e.sa, e.b, "project.start", { projectId: e.b.projectId },
      refusedWith("NOT_ORCHESTRATOR"), "B to answer NOT_ORCHESTRATOR");
    expect(res.body.code).toBe("NOT_ORCHESTRATOR");
  }, ROW_TIMEOUT_MS + GRANT_TIMEOUT_MS);

  test("lowering through the bridge reaches the authority and the next refresh refuses", async () => {
    const e = await boot();
    await reachControl(e, e.sa);
    expect(await authorityGrants(e.license.url, e.a.auth)).toEqual({ orchestrator: true, busControl: false });
    const lowered = await lowerGrants(e.a.abDir, { orchestrator: false });
    expect(lowered.grants.orchestrator).toBe(false);
    expect(await authorityGrants(e.license.url, e.a.auth)).toEqual({ orchestrator: false, busControl: false });
    const res = await requestUntil(e.a, e.sa, e.b, "project.start", { projectId: e.b.projectId },
      refusedWith("NOT_ORCHESTRATOR"), "B to refuse the lowered orchestrator");
    expect(res.body.code).toBe("NOT_ORCHESTRATOR");
  }, ROW_TIMEOUT_MS + GRANT_TIMEOUT_MS * 2);

  test("a session with a bypassed approval policy cannot be started over the bus", async () => {
    const e = await boot();
    await reachControl(e, e.sa);
    const bridge = await e.b.local();
    const created = await localVerb(bridge, createMessage("session:create", {
      requestId: crypto.randomUUID(), name: "elevated", tool: "claude-code", mode: "terminal", approvalPolicy: "bypass",
    }));
    const sessionId = created.session.id as string;
    const res = await request(e.a, e.sa, e.b, "session.start", { projectId: e.b.projectId, sessionId });
    expect(res.status).toBe(403);
    expect(res.body.code).toBe("SESSION_NOT_BUS_ELIGIBLE");
  }, ROW_TIMEOUT_MS + GRANT_TIMEOUT_MS);
});
