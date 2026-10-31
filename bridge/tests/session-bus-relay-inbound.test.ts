// The host-level gate a verified relay delivery passes through, and the one
// property that lives between the transport and the coordinator: a message is
// applied once however many times the relay offers it.
//
// `handleBusInbound` is private on purpose (the transport is its only caller),
// so these reach it the way the transport does, through the field.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { generateKeyPairSync, randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { BusServerMessage, MachineEntry } from "antgrid-wire";
import { createHostPolicyFixture } from "./host-policy-fixture";
import { TestRemoteHostConnection } from "./test-peer-session-owner";
import type { HostServer } from "../src/host-server";
import { generateEphemeralKeypair } from "../src/key-exchange";
import { setLogLevel } from "../src/logger";
import { computeProjectId } from "../src/project-id";
import { createMessage, type AbMessage } from "../src/protocol";
import { SessionBusCoordinator } from "../src/session-bus/coordinator";
import { upsertPairBudget, type PairBudgetState } from "../src/session-bus/pair-budget";
import {
  RelayBusTransport,
  type InboundVerdict,
  type TransportOutcome,
  type VerifiedInbound,
} from "../src/session-bus/relay-transport";
import { openSeenStore } from "../src/session-bus/seen-store";
import { sealBus, type InnerHeader } from "../src/session-bus/seal";

setLogLevel("error");

const SELF_MACHINE = randomUUID();
const REMOTE_MACHINE = randomUUID();

let host: HostServer | null = null;
let prevAbDir: string | undefined;
let abDir: string;
const folders: string[] = [];

beforeEach(() => {
  prevAbDir = process.env.ANTGRID_DIR;
  abDir = mkdtempSync(join(tmpdir(), "antgrid-bus-inbound-"));
  process.env.ANTGRID_DIR = abDir;
});

afterEach(async () => {
  await host?.shutdown();
  host = null;
  if (prevAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = prevAbDir;
  try { rmSync(abDir, { recursive: true, force: true }); } catch { /* Windows watcher handle */ }
  while (folders.length) {
    try { rmSync(folders.pop()!, { recursive: true, force: true }); } catch { /* same */ }
  }
});

async function waitFor(predicate: () => boolean, what: string, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

function tempFolder(): string {
  const f = mkdtempSync(join(tmpdir(), "antgrid-bus-inbound-proj-"));
  folders.push(f);
  writeFileSync(join(f, "antgrid.yaml"), "name: inbound\n");
  return f;
}

/** Opens [folder] as a local project and registers one shared session in it,
 *  which never starts a PTY: the session is addressable and not running. */
async function openSession(h: HostServer, folder: string, name: string): Promise<{ projectId: string; sessionId: string }> {
  const projectId = computeProjectId(folder);
  const opened = await h.open(projectId, folder, "local");
  if (!opened.connect) throw new Error("expected a loopback connect info");
  const ws = new WebSocket(`ws://127.0.0.1:${opened.connect.port}`);
  await new Promise<void>((resolve, reject) => {
    ws.onopen = () => resolve();
    ws.onerror = (e) => reject(e);
  });
  const inbox: any[] = [];
  ws.onmessage = (ev) => inbox.push(JSON.parse(String(ev.data)));
  ws.send(JSON.stringify({ type: "hello", token: opened.connect.token, appPid: 1, appVersion: "test" }));
  await waitFor(() => inbox.some((m) => m.type === "ready"), `${name} loopback ready`);
  const requestId = crypto.randomUUID();
  ws.send(JSON.stringify(createMessage("session:create", { requestId, name })));
  await waitFor(() => inbox.some((m) => m.type === "session:result" && m.requestId === requestId), `${name} created`);
  const sessionId = inbox.find((m) => m.type === "session:result" && m.requestId === requestId).session.id as string;
  ws.close();
  return { projectId, sessionId };
}

function registerMachine(h: HostServer): void {
  (h as any).controlPlaneRelay = new TestRemoteHostConnection({
    identity: { deviceId: SELF_MACHINE, deviceName: "test", createdAt: "" },
  });
}

function policies(h: HostServer): { remote: { setEnabled(on: boolean): boolean }; reach: { setEnabled(on: boolean): boolean } } {
  return { remote: (h as any).remoteAccessPolicy, reach: (h as any).agentReachPolicy };
}

function handle(h: HostServer, v: VerifiedInbound): Promise<InboundVerdict> {
  return (h as any).handleBusInbound(v);
}

function frameTo(to: { projectId: string; sessionId: string }, over: { contextId?: string; fromMachine?: string } = {}): AbMessage {
  const from = { machineId: over.fromMachine ?? REMOTE_MACHINE, projectId: "p-remote", sessionId: "s-remote" };
  const contextId = over.contextId ?? "s-remote";
  const target = { machineId: SELF_MACHINE, ...to };
  return createMessage("session-bus:post", {
    from,
    to: target,
    contextId,
    threadId: null,
    envelope: {
      messageId: randomUUID(),
      threadId: null,
      contextId,
      parts: [{ kind: "text", text: "hello across machines" }],
      metadata: { peer: from, summary: "hello", timestamp: Date.now() },
    },
  });
}

function verified(body: unknown, over: Partial<VerifiedInbound> = {}): VerifiedInbound {
  const header: InnerHeader = {
    v: 1, from: REMOTE_MACHINE, to: SELF_MACHINE, id: randomUUID(), role: "agent", kind: "message",
    sentAt: Date.now(), expiresAt: Date.now() + 60_000,
  };
  return { from: REMOTE_MACHINE, id: header.id, header, body, role: "agent", ...over };
}

async function readyHost(): Promise<{ h: HostServer; a: { projectId: string; sessionId: string }; folderA: string }> {
  const h = createHostPolicyFixture({});
  host = h;
  registerMachine(h);
  const folderA = tempFolder();
  const a = await openSession(h, folderA, "session-a");
  policies(h).remote.setEnabled(true);
  return { h, a, folderA };
}

const busOf = (h: HostServer): SessionBusCoordinator => (h as any).sessionBus;

test("remote access off refuses everything, before looking at the body", async () => {
  const h = createHostPolicyFixture({});
  host = h;
  registerMachine(h);
  const a = await openSession(h, tempFolder(), "session-a");
  expect(policies(h).remote.setEnabled(false)).toBeDefined();

  const verdict = await handle(h, verified(frameTo(a)));
  expect(verdict).toEqual({ outcome: "refused", code: "REMOTE_ACCESS_OFF" });
  expect(busOf(h).mailbox(a.sessionId).posts).toHaveLength(0);
}, 20_000);

test("reach off refuses a message that opens a context, and still admits an answer on a lead context", async () => {
  const { h, a } = await readyHost();
  policies(h).reach.setEnabled(false);

  const opening = await handle(h, verified(frameTo(a, { contextId: "s-remote" })));
  expect(opening).toEqual({ outcome: "refused", code: "NOT_ALLOWED_AGENT_REACH" });
  expect(busOf(h).mailbox(a.sessionId).posts).toHaveLength(0);

  // A lead context is named after the session that opened it, so what arrives on
  // it is an answer to this machine's own session.
  const answer = await handle(h, verified(frameTo(a, { contextId: a.sessionId })));
  expect(answer).toEqual({ outcome: "applied" });
  expect(busOf(h).mailbox(a.sessionId).posts).toHaveLength(1);
}, 20_000);

test("a session this machine does not have is refused UNKNOWN_PEER once the index is hydrated", async () => {
  const { h, a } = await readyHost();
  const verdict = await handle(h, verified(frameTo({ projectId: a.projectId, sessionId: "s-nobody" })));
  expect(verdict).toEqual({ outcome: "refused", code: "UNKNOWN_PEER" });
}, 20_000);

test("a cold project is warmed and the message is applied", async () => {
  const { h } = await readyHost();
  const folderB = tempFolder();
  const b = await openSession(h, folderB, "session-b");
  await h.stop(b.projectId);
  expect(h.list().some((p) => p.projectId === b.projectId)).toBe(false);

  const verdict = await handle(h, verified(frameTo(b)));
  expect(verdict).toEqual({ outcome: "applied" });
  expect(h.list().some((p) => p.projectId === b.projectId)).toBe(true);
  expect(busOf(h).mailbox(b.sessionId).posts).toHaveLength(1);
}, 30_000);

test("a delivery that lands before the index hydrates waits, and is applied after, never refused", async () => {
  const { h, a } = await readyHost();
  const index = (h as any).sessionIndex as { didHydrate: boolean };
  let release!: () => void;
  index.didHydrate = false;
  (h as any).sessionIndexSettled = new Promise<void>((r) => { release = r; });

  let settled: InboundVerdict | null = null;
  const pending = handle(h, verified(frameTo(a))).then((v) => { settled = v; return v; });
  await new Promise((r) => setTimeout(r, 100));
  // No verdict yet, so nothing is acknowledged: a miss here would read exactly
  // like an unknown session and end the exchange for mail this machine owns.
  expect(settled).toBeNull();

  index.didHydrate = true;
  release();
  expect(await pending).toEqual({ outcome: "applied" });
  expect(busOf(h).mailbox(a.sessionId).posts).toHaveLength(1);
}, 20_000);

test("an index that never hydrates defers rather than refusing", async () => {
  const { h, a } = await readyHost();
  (h as any).sessionIndex.didHydrate = false;
  (h as any).sessionIndexSettled = Promise.resolve();

  const verdict = await handle(h, verified(frameTo(a)));
  expect(verdict).toEqual({ outcome: "defer" });
  expect(busOf(h).mailbox(a.sessionId).posts).toHaveLength(0);
}, 20_000);

test("a body that is not a bus message, or that disagrees with the signed header, is refused", async () => {
  const { h, a } = await readyHost();

  expect(await handle(h, verified({ type: "session-bus:post" }))).toEqual({ outcome: "refused", code: "MALFORMED" });
  expect(await handle(h, verified("not an object"))).toEqual({ outcome: "refused", code: "MALFORMED" });

  // The body names a different sender than the header the sender signed.
  const forged = frameTo(a, { fromMachine: randomUUID() });
  expect(await handle(h, verified(forged))).toEqual({ outcome: "refused", code: "HEADER_MISMATCH" });

  // And a body addressed to some other machine.
  const misaddressed = createMessage("session-bus:post", {
    ...(frameTo(a) as any),
    to: { machineId: randomUUID(), projectId: a.projectId, sessionId: a.sessionId },
  });
  expect(await handle(h, verified(misaddressed))).toEqual({ outcome: "refused", code: "HEADER_MISMATCH" });

  // A request kind is not a method this build serves.
  const request = verified(frameTo(a));
  request.header = { ...request.header, kind: "request" };
  expect(await handle(h, request)).toEqual({ outcome: "refused", code: "METHOD_NOT_ALLOWED" });
  expect(busOf(h).mailbox(a.sessionId).posts).toHaveLength(0);
}, 20_000);

// -- duplicate delivery through the transport --------------------------------

function ed25519Pair() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  const seed = privateKey.export({ type: "pkcs8", format: "der" }).subarray(-32);
  const pub = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  return { seed: Buffer.from(seed).toString("base64"), pub: Buffer.from(pub).toString("base64") };
}

function busPair() {
  const k = generateEphemeralKeypair();
  return { privateKey: k.privateKey.toString("base64"), publicKey: k.publicKey.toString("base64") };
}

test("a duplicate delivery is applied once and charges the pair budget once", async () => {
  const me = { id: SELF_MACHINE, sign: ed25519Pair(), bus: busPair() };
  const them = { id: REMOTE_MACHINE, sign: ed25519Pair(), bus: busPair() };
  const SESSION = "s-local";
  const records = new Map<string, PairBudgetState[]>();
  let writes = 0;
  const coordinator = new SessionBusCoordinator({
    abDir,
    projectIdFor: () => "p-local",
    self: (sessionId) => sessionId === SESSION
      ? {
        key: { machineId: me.id, projectId: "p-local", sessionId },
        ref: { machineId: me.id, projectId: "p-local", sessionId },
      }
      : null,
    pairBudget: {
      recordsFor: (sessionId) => records.get(sessionId) ?? [],
      write: (sessionId, next) => {
        writes += 1;
        records.set(sessionId, upsertPairBudget(records.get(sessionId) ?? [], next));
      },
    },
  });
  const entry: MachineEntry = {
    deviceId: them.id, displayName: "them", machineName: null, ed25519Pub: them.sign.pub,
    busPublicKey: them.bus.publicKey, orchestrator: false, busControl: false,
  };
  const directory = {
    current: () => ({ machines: [entry], allowed: true }) as never,
    machine: (id: string) => (id === them.id ? entry : null),
    busKeyFor: (id: string) => (id === them.id ? them.bus.publicKey : null),
    selfOrchestrator: () => false,
    ensureFresh: async () => true,
    kick: () => {},
  };
  const sentFrames: unknown[] = [];
  const outcomes: TransportOutcome[] = [];
  let applied = 0;
  const transport = new RelayBusTransport({
    selfDeviceId: () => me.id,
    signSeed: () => me.sign.seed,
    busKey: () => me.bus,
    directory: directory as never,
    link: () => ({
      sendBus: (f: unknown) => { sentFrames.push(f); return true; },
      busLinkState: () => "ready" as const,
      busNow: () => Date.now(),
    }),
    remoteAccessEnabled: () => true,
    seen: openSeenStore(abDir),
    onInbound: async (v) => {
      applied += 1;
      return coordinator.handleInbound(v.body as AbMessage) === "applied"
        ? { outcome: "applied" }
        : { outcome: "refused", code: "UNKNOWN_PEER" };
    },
    onOutcome: (_id, _to, o) => outcomes.push(o),
  });
  try {
    const body = createMessage("session-bus:post", {
      from: { machineId: them.id, projectId: "p-remote", sessionId: "s-remote" },
      to: { machineId: me.id, projectId: "p-local", sessionId: SESSION },
      contextId: "s-remote",
      threadId: null,
      envelope: {
        messageId: randomUUID(),
        threadId: null,
        contextId: "s-remote",
        parts: [{ kind: "text", text: "once" }],
        metadata: { peer: { machineId: them.id, projectId: "p-remote", sessionId: "s-remote" }, summary: "once", timestamp: Date.now() },
      },
    });
    const id = randomUUID();
    const header: InnerHeader = {
      v: 1, from: them.id, to: me.id, id, role: "agent", kind: "message",
      sentAt: Date.now(), expiresAt: Date.now() + 60_000,
    };
    const sealed = sealBus({
      header, body: JSON.stringify(body), signSeedB64: them.sign.seed, recipientBusPubB64: me.bus.publicKey,
    });
    if (!sealed.ok) throw new Error(sealed.code);
    const deliver = { type: "bus:deliver", id, from: them.id, blob: sealed.blob } as BusServerMessage;

    transport.handleFrame(deliver);
    await waitFor(() => sentFrames.length >= 1, "the first acknowledgement");
    transport.handleFrame(deliver);
    await waitFor(() => sentFrames.length >= 2, "the repeated acknowledgement");

    expect(applied).toBe(1);
    expect(coordinator.messages(SESSION).entries.filter((e) => e.direction === "in")).toHaveLength(1);
    expect(writes).toBe(1);
    // Both offers are acknowledged, or the sender would keep resending the
    // second one for its whole life.
    expect(sentFrames.every((f) => (f as { type: string }).type === "bus:ack")).toBe(true);
  } finally {
    transport.stop();
    coordinator.stop();
  }
}, 20_000);
