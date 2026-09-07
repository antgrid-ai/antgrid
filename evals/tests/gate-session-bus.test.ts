// evals/tests/gate-session-bus.test.ts
import { test, expect, afterEach } from "bun:test";
import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { setupTestEnv, waitForHostFile, type TestEnv } from "../helpers/harness";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";
import { createMessage, type AbMessage, type BusEnvelope, type SessionMemberRef } from "../../bridge/src/protocol";
import { renderWake } from "../../bridge/src/session-bus/delivery";
import { firstProjectStream } from "../support/stream";

// The lead's PTY is a stdin sink rather than an agent: this eval asserts WHEN a
// line reaches the terminal, so the guest only has to record what it was given.
// Raw mode keeps the ConPTY line discipline from holding the write back until a
// newline the bridge never sends on its own.
const SINK_SCRIPT = `const fs = require("node:fs");
const sink = process.env.ANTGRID_EVAL_SINK;
try { process.stdin.setRawMode(true); } catch {}
process.stdin.on("data", (d) => { try { fs.appendFileSync(sink, d); } catch {} });
process.stdin.resume();
setInterval(() => {}, 1 << 30);
`;
const SINK_SCRIPT_NAME = "antgrid-eval-sink.cjs";

// The first header line of every wake delivery (delivery.ts's renderWake) — the
// marker this eval counts to prove exactly one line was submitted.
const WAKE_MARKER = "[antgrid session bus] delivery: wake";

const PEER_REF: SessionMemberRef = {
  machineId: "eval-peer-machine",
  projectId: "eval-peer-project",
  sessionId: "eval-peer-session",
  machineLabel: "Peer laptop",
  projectLabel: "peer-checkout",
  sessionName: "peer worker",
};

const SUMMARY = "The failing suite is a stale generated client, not the migration.";

let env: TestEnv | undefined;
let carrier: LocalTestClient | undefined;
let sinkPath: string | undefined;
afterEach(async () => {
  carrier?.close();
  carrier = undefined;
  await env?.teardown();
  env = undefined;
  if (sinkPath) try { rmSync(sinkPath, { force: true }); } catch { /* the PTY may still hold it */ }
  sinkPath = undefined;
});

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

function deliveriesPath(abDir: string, projectId: string): string {
  return join(abDir, "agents", encodeURIComponent(projectId), "session-bus", "deliveries.json");
}

/** The lines the bridge is holding for a session, as the queue persisted them.
 *  A line is written before delivery is attempted and removed only once the
 *  submit succeeded, so this file IS the held-vs-submitted distinction. */
function queuedLines(abDir: string, projectId: string, sessionId: string): any[] {
  const path = deliveriesPath(abDir, projectId);
  if (!existsSync(path)) return [];
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8"));
    return (parsed.lines ?? []).filter((l: any) => l.sessionId === sessionId);
  } catch {
    // A concurrent atomic rewrite is the only reader error worth tolerating.
    return [];
  }
}

function sinkText(path: string): string {
  return existsSync(path) ? readFileSync(path, "utf8") : "";
}

function countMarkers(text: string): number {
  return text.split(WAKE_MARKER).length - 1;
}

async function until<T>(fn: () => T | undefined, timeoutMs: number, what: string): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const hit = fn();
    if (hit !== undefined) return hit;
    if (Date.now() >= deadline) throw new Error(`timed out waiting for ${what}`);
    await sleep(25);
  }
}

async function postJson(url: string, body: unknown, bearer?: string): Promise<any> {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(bearer ? { authorization: `Bearer ${bearer}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  try { return JSON.parse(text); } catch { throw new Error(`${url} -> ${res.status} ${text.slice(0, 200)}`); }
}

/** One project verb, answered on its own requestId. `session:result` carries no
 *  echo of the verb, so the id is the only thing tying reply to request. */
async function sessionVerb(app: TestEnv["app"], streamId: string, msg: AbMessage): Promise<any> {
  app.sendOnStream(streamId, msg);
  const requestId = (msg as any).requestId;
  const res = await app.waitFor(
    (m: any) => m._streamId === streamId && m.type === "session:result" && m.requestId === requestId,
    15_000,
  );
  expect(res.ok).toBe(true);
  return res;
}

function envelopeFrom(taskId: string, contextId: string, summary: string, text: string): BusEnvelope {
  return {
    messageId: randomUUID(),
    taskId,
    contextId,
    parts: [{ kind: "text", text }],
    // `peer` on an envelope is the SENDER's own ref (coordinator.stamp), so the
    // peer machine names itself here.
    metadata: { peer: PEER_REF, summary, timestamp: Date.now() },
  } as BusEnvelope;
}

// The whole lead-side round trip in one process: assign out over loopback, the
// peer's replies in over the project stream, and the wake held at the turn
// boundary. Terminal mode only — a chat-mode lead needs a real structured agent
// driver, which no eval fixture provides.
test("Lead assigns over loopback, the peer's completion wakes it at the turn boundary", async () => {
  sinkPath = join(tmpdir(), `antgrid-eval-sink-${randomUUID()}.txt`);
  const sink = sinkPath;

  env = await setupTestEnv({
    fixtureName: "basic",
    env: { ANTGRID_EVAL_SINK: sink },
    prepareProject: (dir) => { writeFileSync(join(dir, SINK_SCRIPT_NAME), SINK_SCRIPT); },
  });
  const streamId = await firstProjectStream(env.app, env.projectId, 10_000);

  // --- the carrier: the lead's own desktop app on the loopback owner socket ---
  // D7: the lead bridge can never reach the peer bridge, so every outbound frame
  // is addressed to this socket and nowhere else.
  const host = await waitForHostFile(env.abDir, 15_000);
  const started = await postJson(`http://127.0.0.1:${host.controlPort}/control`, {
    id: "eval-carrier", type: "project:start", projectId: env.projectId,
  }, host.token);
  expect(started.ok).toBe(true);
  const connect = started.connect as LocalConnectInfo;

  const carrierFrames: AbMessage[] = [];
  carrier = new LocalTestClient();
  carrier.on((m) => { carrierFrames.push(m); });
  await carrier.connect(connect, { capabilities: { sessionBusCarrier: true } });

  // --- (a) a lead session, with one recorded peer member ---
  const created = await sessionVerb(env.app, streamId, createMessage("session:create", {
    requestId: randomUUID(),
    name: "lead",
    // A custom command, because the fixture declares no agent: the sink is the
    // only guest this eval needs.
    command: `node ${SINK_SCRIPT_NAME}`,
    mode: "terminal",
  }));
  const leadSessionId: string = created.session.id;

  // Running before the turn opens: work-status only opens a turn for a session
  // it already knows is live (otherwise the start is held as pending).
  await sessionVerb(env.app, streamId, createMessage("session:start", {
    requestId: randomUUID(), sessionId: leadSessionId,
  }));

  await sessionVerb(env.app, streamId, createMessage("session:member-record", {
    requestId: randomUUID(), sessionId: leadSessionId, member: PEER_REF, role: "peer",
  }));

  const apiPort = (await Bun.file(join(env.abDir, "api.port")).text()).trim();
  const roleRes = await fetch(`http://127.0.0.1:${apiPort}/session-bus/role?terminalId=${encodeURIComponent(leadSessionId)}`);
  const role = await roleRes.json();
  expect(role.role).toBe("lead");
  expect(role.lead).toBe(true);
  // The bridge's own bus address half — asserted from the bridge rather than
  // assumed, because a frame addressed to anything else is dropped unacked.
  const machineId: string = role.machineId;
  expect(typeof machineId).toBe("string");
  const leadKey = { machineId, projectId: env.projectId, sessionId: leadSessionId };

  // The turn is held open BEFORE any bus traffic, so no window exists in which a
  // delivery could be submitted for a reason other than the boundary under test.
  await postJson(`http://127.0.0.1:${apiPort}/turn-start`, { terminalId: leadSessionId });

  // --- (b) assign, over the same loopback route the MCP tool calls ---
  const assigned = await postJson(
    `http://127.0.0.1:${apiPort}/session-bus/tasks?terminalId=${encodeURIComponent(leadSessionId)}`,
    {
      peer: PEER_REF.sessionId,
      summary: "Reproduce the suite failure on your machine",
      instruction: "Run the web suite and report the first failing assertion.",
    },
  );
  expect(assigned.ok).toBe(true);
  const taskId: string = assigned.taskId;

  // --- (c) the assign reaches the carrier, and only the carrier ---
  const assignFrame: any = await until(
    () => carrierFrames.find((m: any) => m.type === "session-bus:assign" && m.taskId === taskId),
    15_000, "the assign frame on the loopback owner socket",
  );
  expect(assignFrame.from).toEqual(leadKey);
  expect(assignFrame.to).toEqual({
    machineId: PEER_REF.machineId, projectId: PEER_REF.projectId, sessionId: PEER_REF.sessionId,
  });
  expect(assignFrame.seq).toBe(0);

  // Spec 4.1's first invariant: the human's phone is a relay subscriber, and no
  // session-bus frame may ever reach it. `waitFor` scans what has already
  // arrived before it waits, so this covers the whole run to here, not just the
  // window that follows.
  const leaked = await env.app.waitFor(
    (m: any) => typeof m?.type === "string" && m.type.startsWith("session-bus:"),
    3_000,
  ).catch(() => null);
  expect(leaked).toBeNull();

  // --- (d) the peer answers, as the carrier would deliver it ---
  const send = (msg: AbMessage) => env!.app.sendOnStream(streamId, msg);
  const peerKey = { machineId: PEER_REF.machineId, projectId: PEER_REF.projectId, sessionId: PEER_REF.sessionId };
  const base = { from: peerKey, to: leadKey, contextId: leadSessionId };

  // The assign's own ack retires the lead's outbox before the first transition.
  send(createMessage("session-bus:ack", { ...base, taskId, seq: 0, ok: true }));

  // seq 1: the peer picked the task up. `submitted -> completed` is not a legal
  // transition, so `working` is not decoration — it is the only route to a
  // completion the lead will apply.
  send(createMessage("session-bus:transition", {
    ...base, taskId, seq: 1, state: "working",
    envelope: envelopeFrom(taskId, leadSessionId, "Started on the suite", "picking this up"),
  }));
  await until(
    () => carrierFrames.find((m: any) => m.type === "session-bus:ack" && m.taskId === taskId && m.seq === 1),
    15_000, "the lead's ack of the peer's `working`",
  );

  send(createMessage("session-bus:transition", {
    ...base, taskId, seq: 2, state: "completed",
    envelope: envelopeFrom(taskId, leadSessionId, SUMMARY, "regenerate the prisma client and it passes"),
  }));
  await until(
    () => carrierFrames.find((m: any) => m.type === "session-bus:ack" && m.taskId === taskId && m.seq === 2),
    15_000, "the lead's ack of the peer's `completed`",
  );

  // --- (e) held while the turn is open ---
  const held: any = await until(
    () => queuedLines(env!.abDir, env!.projectId, leadSessionId).find((l) => l.kind === "wake"),
    15_000, "the wake line to be queued",
  );
  // The envelope's text part travels too — the summary alone is a title, and
  // the card is what the lead reads in the turn the result lands.
  const expectedWake = renderWake({
    peer: PEER_REF,
    taskId,
    state: "completed",
    summary: SUMMARY,
    result: "regenerate the prisma client and it passes",
  });
  expect(held.text).toBe(expectedWake);
  expect(held.text).toContain("regenerate the prisma client and it passes");

  // Nothing submitted yet, and nothing submitted while the turn stays open.
  expect(sinkText(sink)).toBe("");
  await sleep(1_000);
  expect(sinkText(sink)).toBe("");
  expect(queuedLines(env.abDir, env.projectId, leadSessionId).length).toBe(1);

  // --- the turn closes, and exactly one line is submitted ---
  // `task_complete` is the Stop-hook notification: the same fold that ends a
  // turn for the phone's work status is what drains the queue.
  await postJson(`http://127.0.0.1:${apiPort}/notify`, {
    type: "task_complete", terminalId: leadSessionId, message: "done",
  });

  const submitted = await until(
    () => { const t = sinkText(sink); return t.includes(WAKE_MARKER) ? t : undefined; },
    20_000, "the wake line to reach the PTY",
  );
  expect(countMarkers(submitted)).toBe(1);
  expect(submitted).toContain(SUMMARY);

  // The queue is the delivery record, so a submitted line must leave it — a line
  // that stays would be re-submitted at every later boundary.
  await until(
    () => (queuedLines(env!.abDir, env!.projectId, leadSessionId).length === 0 ? true : undefined),
    10_000, "the queue to drop the delivered line",
  );

  // Still nothing on the phone's stream after the whole exchange.
  const leakedAfter = await env.app.waitFor(
    (m: any) => typeof m?.type === "string" && m.type.startsWith("session-bus:"),
    2_000,
  ).catch(() => null);
  expect(leakedAfter).toBeNull();
}, 180_000);
