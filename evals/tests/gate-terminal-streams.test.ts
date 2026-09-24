// Stage A wave A2 gate: terminal attachment streams. A subscribed terminal
// now rides its own native QUIC stream (docs/iroh-reduction/stage-A-waves.md
// §3 "A2"; the frozen contract is docs/iroh-reduction/stage-A-A2-contract.md).
// `RelayClient.openTerminalStream` drives the stream directly — it does NOT
// go through `openTerminalAttachment`'s app-side logic (that is Dart's own
// production path, exercised by `terminal_attachment_test.dart` and the Dart
// eval client's `terminal-attach*` actions in
// `scenarios/dart-client-e2e/dart-terminal.test.ts`) — so a row here is about
// the WIRE the bridge serves, independent of any one client's reconnect or
// re-sync policy.
//
// `terminal:input`, `terminal:resize` and `terminal:start` stay on the
// project stream throughout (D-3/D1 of the contract); only the eight record
// types listed in the contract's §0 ride the terminal stream itself.
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createTestProject } from "../helpers/fixtures";
import { computeProjectId } from "../../bridge/src/project-id";
import { readHostFile } from "../../bridge/src/host-discovery";
import { createMessage } from "../../bridge/src/protocol";
import { firstProjectStream } from "../support/stream";
import { RelayClient, type TerminalStreamClient } from "../helpers/relay-client";
import {
  TERMINAL_HISTORY_PAGE_ROWS,
  TERMINAL_PROTOCOL_VERSION,
  TERMINAL_VIEWER_MAX_FRAMES,
} from "../../bridge/src/terminal-frames/protocol";

async function loopbackControl(abDir: string, body: object): Promise<any> {
  const hf = readHostFile(join(abDir, "host.json"));
  if (!hf) throw new Error("no host.json for loopback control");
  const res = await fetch(`http://127.0.0.1:${hf.controlPort}/control`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${hf.token}` },
    body: JSON.stringify(body),
  });
  return res.json();
}

/** Round-trips `state.snapshot` on the (still-open) SESSION stream and asserts
 *  `ok:true` — proof the connection survived whatever the terminal stream
 *  under test just did. Mirrors gate-stream-admission.test.ts. */
async function assertSessionAlive(app: RelayClient, label: string): Promise<void> {
  const requestId = `gate-terminal-streams-${label}`;
  const responseP = app.waitFor((m: any) => m.type === "response" && m.requestId === requestId, 8_000);
  app.sendEncrypted(createMessage("request", { requestId, method: "state.snapshot", params: { types: ["*"] } }));
  const res = (await responseP) as { ok?: boolean };
  expect(res.ok).toBe(true);
}

/** `client.ended` never rejects, so a bridge that failed to end the stream
 *  would otherwise hang the row instead of failing it. */
async function expectEndedSoon(client: TerminalStreamClient, timeoutMs = 5_000): Promise<void> {
  const timedOut = Symbol("timeout");
  const result = await Promise.race([
    client.ended.then(() => "ended" as const),
    Bun.sleep(timeoutMs).then(() => timedOut),
  ]);
  expect(result).toBe("ended");
}

async function startTerminal(
  app: RelayClient, streamId: string, terminalId: string, command: string, args: string[],
): Promise<any> {
  app.sendOnStream(streamId, createMessage("terminal:start", { terminalId, name: terminalId, command, args }));
  const started = await app.waitFor((m: any) => m.type === "terminal:started" &&
    m._streamId === streamId && m.terminalId === terminalId, 5_000);
  expect(started.terminalId).toBe(terminalId);
  return started;
}

/** Cleanup only — never fails the row over a missing ENDED (see
 *  gate-terminal-frames.test.ts's identical helper). */
async function stopTerminal(app: RelayClient, streamId: string, terminalId: string): Promise<void> {
  app.sendOnStream(streamId, createMessage("terminal:stop", { terminalId }));
  await app.waitFor(
    (m: any) => m.type === "terminal:display:status" && m._streamId === streamId &&
      m.terminalId === terminalId && m.code === "ENDED",
    10_000,
  ).catch(() => {});
}

function resizeTerminal(app: RelayClient, streamId: string, terminalId: string, cols: number, rows: number): void {
  app.sendOnStream(streamId, createMessage("terminal:resize", { intent: "takeover", terminalId, cols, rows, clientId: "eval-stream-viewer" }));
}

function subscribeOnStream(
  client: TerminalStreamClient, requestId: string, terminalId: string, version = TERMINAL_PROTOCOL_VERSION,
): Promise<void> {
  return client.send(createMessage("terminal:subscribe", { terminalId, version, requestId }));
}

function ackOnStream(client: TerminalStreamClient, frame: any): Promise<void> {
  return client.send(createMessage("terminal:ack", {
    terminalId: frame.terminalId, runId: frame.runId, attachmentId: frame.attachmentId, sequence: frame.sequence,
  }));
}

function nextStreamFrame(client: TerminalStreamClient, timeoutMs = 10_000): Promise<any> {
  return client.next((r) => r.type === "terminal:frame", timeoutMs);
}

/** Opens a terminal stream and drives it through a normal subscribe — the
 *  shape most rows below want; the rows about admission or a malformed first
 *  record call `env.app.openTerminalStream` directly instead. */
async function attachTerminalStream(
  app: RelayClient, projectId: string, terminalId: string, opts: { version?: number; checkoutId?: string } = {},
): Promise<{ client: TerminalStreamClient; requestId: string; subscribed: any }> {
  const requestId = crypto.randomUUID();
  const client = await app.openTerminalStream({ projectId, requestId, checkoutId: opts.checkoutId });
  await subscribeOnStream(client, requestId, terminalId, opts.version);
  const subscribed = await client.next((r) => r.type === "terminal:subscribed" && r.requestId === requestId);
  return { client, requestId, subscribed };
}

describe("gate: terminal attachment streams", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    // History recording is opt-in for a host under test, as in
    // gate-terminal-frames.test.ts; without it every boundary reads "disabled".
    env = await setupTestEnv({ fixtureName: "basic", env: { ANTGRID_TERMINAL_HISTORY_TEST: "1" } });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("a terminal stream carries subscribed first, then frames in increasing sequence, and nothing for its attachment rides the project stream", async () => {
    const terminalId = "stream-hazard-a";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "let i=0; setInterval(()=>process.stdout.write('HAZA_'+(i++)+'\\n'), 15);",
      ]);
      const { client, subscribed } = await attachTerminalStream(env.app, env.projectId, terminalId);
      expect(subscribed.terminalId).toBe(terminalId);

      let lastSequence = -1;
      let framesSeen = 0;
      const deadline = Date.now() + 8_000;
      while (framesSeen < 5 && Date.now() < deadline) {
        const frame = await nextStreamFrame(client, 3_000).catch(() => null);
        if (!frame) continue;
        expect(frame.sequence).toBeGreaterThan(lastSequence);
        lastSequence = frame.sequence;
        framesSeen++;
        await ackOnStream(client, frame);
      }
      expect(framesSeen).toBeGreaterThan(0);
      // Hazard A, on the wire: nothing bound to this attachment ever lands on
      // the project stream's own envelope.
      expect(env.app.queuedCount((m: any) =>
        m.type === "terminal:frame" && m._streamId === streamId && m.terminalId === terminalId,
      )).toBe(0);
      expect(env.app.queuedCount((m: any) =>
        m.type === "terminal:subscribed" && m._streamId === streamId && m.terminalId === terminalId,
      )).toBe(0);
      client.reset();
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("ENDED arrives on the stream after the frame at finalSequence, then the bridge ends the stream", async () => {
    const terminalId = "stream-hazard-b";
    const marker = `HAZ_B_${Date.now()}`;
    await startTerminal(env.app, streamId, terminalId, "node", [
      "-e", `console.log('BOOT'); setTimeout(() => { console.log('${marker}'); process.exit(0); }, 1200);`,
    ]);
    const { client } = await attachTerminalStream(env.app, env.projectId, terminalId);

    let lastFrame: any = null;
    let ended: any = null;
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline && !ended) {
      const record = await client.next(
        (r) => r.type === "terminal:frame" || (r.type === "terminal:display:status" && r.code === "ENDED"),
        Math.max(1, deadline - Date.now()),
      );
      if (record.type === "terminal:frame") {
        lastFrame = record;
        await ackOnStream(client, record);
      } else {
        ended = record;
      }
    }
    expect(ended).not.toBeNull();
    expect(ended.exitCode).toBe(0);
    expect(lastFrame?.ansi).toContain(marker);
    // Carry-over 1: retirement never aborts frames already handed to the
    // transport, so ENDED is the last record and the FIN right behind it.
    await expectEndedSoon(client);
  }, 30_000);

  test("input and resize stay on the project stream and still reach the attached screen", async () => {
    const terminalId = "stream-input-resize";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "process.stdin.once('data', () => { let i=0; setInterval(()=>process.stdout.write('STDIN_'+(i++)+'\\n'),20); });",
      ]);
      const { client } = await attachTerminalStream(env.app, env.projectId, terminalId);

      resizeTerminal(env.app, streamId, terminalId, 100, 30);
      env.app.sendOnStream(streamId, createMessage("terminal:input", { terminalId, data: "go\r" }));

      let matched = false;
      const deadline = Date.now() + 10_000;
      while (!matched && Date.now() < deadline) {
        const frame = await nextStreamFrame(client, 2_000).catch(() => null);
        if (!frame) continue;
        await ackOnStream(client, frame);
        matched = frame.cols === 100 && frame.rows === 30 && String(frame.ansi).includes("STDIN_");
      }
      expect(matched).toBe(true);
      client.reset();
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("a never-acked consumer is capped at TERMINAL_VIEWER_MAX_FRAMES in flight on its stream and resumes after an ack", async () => {
    const terminalId = "stream-viewer-cap";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "let i=0; setInterval(() => process.stdout.write('C'.repeat(100) + (i++) + '\\n'), 5);",
      ]);
      const { client } = await attachTerminalStream(env.app, env.projectId, terminalId);

      const queuedFrames = () => client.records.filter((r) => r.type === "terminal:frame").length;
      const capDeadline = Date.now() + 4_500;
      while (queuedFrames() < TERMINAL_VIEWER_MAX_FRAMES && Date.now() < capDeadline) await Bun.sleep(50);
      await Bun.sleep(2_000);
      expect(queuedFrames()).toBe(TERMINAL_VIEWER_MAX_FRAMES);

      let lastSequence = -1;
      let drained = 0;
      while (drained < TERMINAL_VIEWER_MAX_FRAMES) {
        const frame = await nextStreamFrame(client, 2_000);
        drained++;
        lastSequence = Math.max(lastSequence, frame.sequence);
        await ackOnStream(client, frame);
      }
      const freshFrame = await nextStreamFrame(client, 3_000);
      expect(freshFrame.sequence).toBeGreaterThan(lastSequence);
      client.reset();
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("finishing the app's half unsubscribes: frames stop, the bridge ends its half, and a fresh stream subscribes again", async () => {
    const terminalId = "stream-finish-unsub";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "setInterval(()=>process.stdout.write('FIN_'+Date.now()+'\\n'), 20);",
      ]);
      const first = await attachTerminalStream(env.app, env.projectId, terminalId);
      const frame1 = await nextStreamFrame(first.client);
      await ackOnStream(first.client, frame1);

      await first.client.finish();
      await expectEndedSoon(first.client);

      // A second attachment for the SAME terminal succeeding, with a fresh
      // attachmentId, is the proof the old one was actually torn down (the
      // synthesized terminal:unsubscribe), not merely the transport closed.
      const second = await attachTerminalStream(env.app, env.projectId, terminalId);
      expect(second.subscribed.attachmentId).not.toBe(frame1.attachmentId);
      const frame2 = await nextStreamFrame(second.client);
      expect(frame2.attachmentId).toBe(second.subscribed.attachmentId);
      await ackOnStream(second.client, frame2);
      second.client.reset();
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("resetting the app's half unsubscribes the same way", async () => {
    const terminalId = "stream-reset-unsub";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "setInterval(()=>process.stdout.write('RST_'+Date.now()+'\\n'), 20);",
      ]);
      const first = await attachTerminalStream(env.app, env.projectId, terminalId);
      const frame1 = await nextStreamFrame(first.client);
      await ackOnStream(first.client, frame1);

      first.client.reset();
      await expectEndedSoon(first.client);

      const second = await attachTerminalStream(env.app, env.projectId, terminalId);
      expect(second.subscribed.attachmentId).not.toBe(frame1.attachmentId);
      const frame2 = await nextStreamFrame(second.client);
      expect(frame2.attachmentId).toBe(second.subscribed.attachmentId);
      await ackOnStream(second.client, frame2);
      second.client.reset();
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("a terminal stream for a catalogued project with no binding is refused NOT_READY in-band and the session stays up", async () => {
    const projBdir = createTestProject("basic", { "__RELAY_URL__": env.relay.url.replace(/\/ws$/, "") });
    try {
      const projB = computeProjectId(projBdir.dir);
      // Catalogued (seenProjects has it) but stopped, so it has no live mux
      // entry — projectBinding(projB) === null (§3.2 check 5, D-2).
      expect((await loopbackControl(env.abDir, {
        id: "open-terminal-streams-b", type: "project:open", projectId: projB, projectPath: projBdir.dir, mode: "remote",
      })).ok).toBe(true);
      expect((await loopbackControl(env.abDir, {
        id: "stop-terminal-streams-b", type: "project:stop", projectId: projB,
      })).ok).toBe(true);

      const before = env.app.nativeConnectionId;
      const client = await env.app.openTerminalStream({ projectId: projB, requestId: crypto.randomUUID() });
      const refusal = await client.next((r) => r.type === "stream:refused");
      expect(refusal.code).toBe("NOT_READY");
      await expectEndedSoon(client);
      expect(env.app.nativeConnectionId).toBe(before);
      await assertSessionAlive(env.app, "not-ready");
    } finally {
      try { projBdir.cleanup(); } catch { /* Windows EBUSY teardown race */ }
    }
  }, 30_000);

  test("a terminal stream naming an uncatalogued project is refused NOT_ALLOWED and the session stays up", async () => {
    const before = env.app.nativeConnectionId;
    const client = await env.app.openTerminalStream({
      projectId: randomBytes(8).toString("hex"),
      requestId: crypto.randomUUID(),
    });
    const refusal = await client.next((r) => r.type === "stream:refused");
    expect(refusal.code).toBe("NOT_ALLOWED");
    await expectEndedSoon(client);
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "uncatalogued");
  });

  test("a first record that is not the matching subscribe ends only that stream and the session stays up", async () => {
    const before = env.app.nativeConnectionId;
    const client = await env.app.openTerminalStream({ projectId: env.projectId, requestId: crypto.randomUUID() });
    // Any well-formed message other than the matching terminal:subscribe
    // breaches the first-record rule (§1).
    await client.send(createMessage("terminal:ack", {
      terminalId: "stream-first-record-breach",
      runId: crypto.randomUUID(),
      attachmentId: crypto.randomUUID(),
      sequence: 0,
    }));
    await expectEndedSoon(client);
    expect(env.app.nativeConnectionId).toBe(before);
    await assertSessionAlive(env.app, "first-record-breach");
  });

  test("an unknown terminal is answered UNKNOWN_TERMINAL by requestId on the stream, then the stream ends", async () => {
    const requestId = crypto.randomUUID();
    const client = await env.app.openTerminalStream({ projectId: env.projectId, requestId });
    await subscribeOnStream(client, requestId, "stream-unknown-terminal");
    const status = await client.next((r) => r.type === "terminal:display:status" && r.requestId === requestId);
    expect(status.code).toBe("UNKNOWN_TERMINAL");
    expect(status.attachmentId).toBeUndefined();
    await expectEndedSoon(client);
    await assertSessionAlive(env.app, "unknown-terminal");
  });

  test("an unsupported version is answered UPGRADE_REQUIRED by requestId on the stream, then the stream ends", async () => {
    const terminalId = "stream-upgrade-required";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "setInterval(() => console.log('UPGRADE_NOISE'), 20);",
      ]);
      const requestId = crypto.randomUUID();
      const client = await env.app.openTerminalStream({ projectId: env.projectId, requestId });
      await subscribeOnStream(client, requestId, terminalId, TERMINAL_PROTOCOL_VERSION + 1);
      const status = await client.next((r) => r.type === "terminal:display:status" && r.requestId === requestId);
      expect(status.code).toBe("UPGRADE_REQUIRED");
      await expectEndedSoon(client);
      await assertSessionAlive(env.app, "upgrade-required");
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("history paging over a terminal stream returns its pages on the stream", async () => {
    const terminalId = "stream-history";
    try {
      // The archive commits in page-sized batches, so a boundary past zero
      // needs more than a full page scrolled off the live screen.
      const total = TERMINAL_HISTORY_PAGE_ROWS * 2;
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", `for (let i = 0; i < ${total}; i++) console.log('HIST_' + i); setInterval(() => {}, 60000);`,
      ]);
      const { client, subscribed } = await attachTerminalStream(env.app, env.projectId, terminalId);
      const { runId, attachmentId } = subscribed;

      let boundary: any = null;
      const deadline = Date.now() + 12_000;
      while (Date.now() < deadline) {
        const frame = await nextStreamFrame(client, 1_000).catch(() => null);
        if (!frame) continue;
        boundary = frame.history;
        await ackOnStream(client, frame);
        if (boundary.nextRowId > 0) break;
      }
      expect(boundary).not.toBeNull();
      expect(boundary.nextRowId).toBeGreaterThan(0);

      const pageRequestId = crypto.randomUUID();
      await client.send(createMessage("terminal:history:request", {
        terminalId, runId, attachmentId, requestId: pageRequestId,
        epoch: boundary.epoch, beforeRowId: boundary.nextRowId,
      }));
      const page = await client.next((r) => r.type === "terminal:history:page" && r.requestId === pageRequestId);
      expect(page.expired).toBe(false);
      expect(page.rows.length).toBeGreaterThan(0);
      expect(page.rows[page.rows.length - 1].rowId).toBe(boundary.nextRowId - 1);
      client.reset();
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 30_000);
});
