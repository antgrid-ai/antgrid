// Terminal-frame mode end to end, over a real relay and a real agent (see
// docs/terminal-frame-implementation-plan.md, "Validation and release gates").
// A frame-capable viewer (`env.app`) negotiates `terminalFramesV1` in its
// `app:ready` capabilities (the harness default), then opts a specific
// terminal into the protocol with `terminal:subscribe` — everything here rides
// the firstProject STREAM (`sendOnStream`), never the control plane.
//
// Rows covered, one `test()` each:
//   - local and relay viewers receive only frames, and unsupported protocol
//     versions receive an upgrade status without raw-output fallback
//   - the 20 frames/sec SEND cap under sustained, gap-free output (the capture
//     half of that gate is not observable from out here — see the row)
//   - the final frame before a natural exit reflects the true final screen —
//     including a write issued on the very tick that calls process.exit — and
//     ENDED carries the exit code
//   - `terminal:exited` and `terminal:notification` still reach a frame-mode
//     viewer: only the passive output stream is withheld from it
//   - a client-initiated stop retains the last frame's content (no blanking)
//   - two terminals resized to different geometries never cross-deliver
//     frames, geometry or screen content
//   - history paging backwards across multiple pages reconstructs every row
//     that scrolled off, ascending within each page and across the merge,
//     with no duplicate and no gap
//   - a real CSI 3J history clear turns the epoch over, and a request against
//     the epoch before it comes back `expired` with a boundary paging can
//     restart from
//   - a same-id respawn mints a fresh runId, the old run's frames stop
//     arriving, and the new run's history starts at epoch 0
//   - a stalled (never-acked) consumer is capped at TERMINAL_VIEWER_MAX_FRAMES
//     in flight and catches up by jumping to the current revision, not by
//     draining a backlog one revision at a time
//
// Deliberately SKIPPED:
//   - the byte-retention eviction trigger for a `history:page`'s `expired`
//     flag (`beforeRowId < firstRowId` under the SAME epoch) — reaching it
//     needs TERMINAL_HISTORY_RUN_BYTES (256 MB) of real archived output,
//     infeasible in an E2E test's time budget. Only the epoch-turnover
//     trigger (`epoch !== history.epoch`) is exercised below.
//
// Every test that starts a LONG-RUNNING writer stops it from a `finally`, so a
// failed assertion still does. An abandoned writer outlives its own `test()`
// and keeps consuming PTY and history resources. The two rows whose guest exits on its own
// (`frame-exit-final`, `frame-lifecycle-events`) have no writer to strand.
//
// Drains are written `await nextFrame(...).catch(() => null)` and bounded by a
// wall clock, never by a bare wait: delivery misses slots on a loaded machine,
// so a bare wait makes the row a stopwatch on scheduling rather than a gate.
//
// Known Windows test noise (NOT failures): fs.watch EPERM/EBUSY on teardown.
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { join } from "node:path";
import { setupTestEnv, type TestEnv } from "../helpers/harness";
import { createMessage } from "../../bridge/src/protocol";
import { readHostFile } from "../../bridge/src/host-discovery";
import { LocalTestClient, type LocalConnectInfo } from "../helpers/local-client";
import { firstProjectStream } from "../support/stream";
import type { RelayClient } from "../helpers/relay-client";
import {
  TERMINAL_PROTOCOL_VERSION, TERMINAL_FRAME_INTERVAL_MS, TERMINAL_VIEWER_MAX_FRAMES,
  TERMINAL_HISTORY_PAGE_ROWS,
} from "../../bridge/src/terminal-frames/protocol";

test("session listing and checkout deletion remain responsive beside a slow terminal viewer", async () => {
  const env = await setupTestEnv({
    fixtureName: "basic",
    prepareProject: async (cwd) => {
      for (const args of [["init"], ["config", "user.email", "eval@antgrid.local"],
        ["config", "user.name", "Antgrid Eval"], ["add", "."], ["commit", "-m", "initial"]]) {
        const proc = Bun.spawn(["git", ...args], { cwd, stdout: "ignore", stderr: "pipe" });
        if (await proc.exited !== 0) throw new Error(await new Response(proc.stderr).text());
      }
    },
  });
  let consuming = true;
  let consume: Promise<void> | undefined;
  try {
    const streamId = await firstProjectStream(env.app, env.projectId, 10_000);
    const createId = crypto.randomUUID();
    env.app.sendOnStream(streamId, createMessage("session:create", {
      requestId: createId, name: "slow-viewer-checkout", isolation: "worktree",
    }));
    const created = await env.app.waitFor((m: any) =>
      m.type === "session:result" && m._streamId === streamId && m.requestId === createId, 20_000);
    expect(created.ok).toBe(true);
    expect(created.session.checkoutKind).toBe("managed-worktree");
    const terminalId = "slow-control-viewer";
    await startTerminal(env.app, streamId, terminalId, "node", ["-e",
      "let i=0;const timer=setInterval(()=>{process.stdout.write('output '+i+++'\\n');if(i===1200){clearInterval(timer);process.stdout.write('FINAL-CONTROL-SCREEN');}},10);"]);
    await subscribeFrames(env.app, streamId, terminalId);
    let finalSeen = false;
    let consumed = 0;
    let consumeError: unknown;
    consume = (async () => {
      while (consuming) {
        await Bun.sleep(350);
        const queued = env.app.queuedCount((m: any) =>
          m.type === "terminal:frame" && m._streamId === streamId && m.terminalId === terminalId);
        expect(queued).toBeLessThanOrEqual(TERMINAL_VIEWER_MAX_FRAMES);
        const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
        if (frame) {
          finalSeen ||= frame.ansi.includes("FINAL-CONTROL-SCREEN");
          consumed++;
          ackFrame(env.app, streamId, frame);
        }
      }
    })().catch((error) => { consumeError = error; });
    const list = async () => {
      const requestId = crypto.randomUUID();
      env.app.sendOnStream(streamId, createMessage("session:list", { requestId }));
      return env.app.waitFor((m: any) => m.type === "session:list:result" &&
        m._streamId === streamId && m.requestId === requestId, 5_000);
    };
    expect((await list()).sessions.some((s: any) => s.id === created.session.id)).toBe(true);
    const deleteId = crypto.randomUUID();
    env.app.sendOnStream(streamId, createMessage("session:delete", {
      requestId: deleteId, sessionId: created.session.id, removeCheckout: true,
    }));
    const deleted = await env.app.waitFor((m: any) => m.type === "session:result" &&
      m._streamId === streamId && m.requestId === deleteId, 15_000);
    expect(deleted.ok).toBe(true);
    for (let i = 0; i < 2; i++) {
      expect((await list()).sessions.some((s: any) => s.id === created.session.id)).toBe(false);
    }
    const ended = await env.app.waitFor((m: any) => m.type === "terminal:display:status" &&
      m._streamId === streamId && m.terminalId === terminalId && m.code === "ENDED", 20_000);
    expect(ended.exitCode).toBe(0);
    expect(finalSeen).toBe(true);
    expect(consumed).toBeGreaterThan(4);
    expect(consumeError).toBeUndefined();
  } finally {
    consuming = false;
    await consume;
    await env.teardown();
  }
}, 60_000);

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

async function startTerminal(
  app: RelayClient, streamId: string, terminalId: string, command: string, args: string[],
): Promise<any> {
  app.sendOnStream(streamId, createMessage("terminal:start", { terminalId, name: terminalId, command, args }));
  const started = await app.waitFor((m: any) => m.type === "terminal:started" &&
    m._streamId === streamId && m.terminalId === terminalId, 5_000);
  expect(started.terminalId).toBe(terminalId);
  return started;
}

/** Kill a terminal a test is done with, tolerating a missing ENDED.
 *
 *  Cleanup, so it never fails a row: by the time this runs every assertion the
 *  test exists for has been made, and turning a green row red over a teardown
 *  timeout would hide the defect it was written to catch. Killing the PTY is
 *  what matters — the writer is what leaks into the next test. */
async function stopTerminal(app: RelayClient, streamId: string, terminalId: string): Promise<void> {
  app.sendOnStream(streamId, createMessage("terminal:stop", { terminalId }));
  await app.waitFor(
    (m: any) => m.type === "terminal:display:status" && m._streamId === streamId &&
      m.terminalId === terminalId && m.code === "ENDED",
    10_000,
  ).catch(() => {});
}

function resizeTerminal(app: RelayClient, streamId: string, terminalId: string, cols: number, rows: number): void {
  app.sendOnStream(streamId, createMessage("terminal:resize", { intent: "takeover", terminalId, cols, rows, clientId: "eval-viewer" }));
}

async function subscribeFrames(app: RelayClient, streamId: string, terminalId: string, timeoutMs = 10_000): Promise<any> {
  const requestId = crypto.randomUUID();
  app.sendOnStream(streamId, createMessage("terminal:subscribe", {
    terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId,
  }));
  const subscribed = await app.waitFor(
    (m: any) => m.type === "terminal:subscribed" && m._streamId === streamId && m.requestId === requestId,
    timeoutMs,
  );
  expect(subscribed.terminalId).toBe(terminalId);
  return subscribed;
}

function ackFrame(app: RelayClient, streamId: string, frame: any): void {
  app.sendOnStream(streamId, createMessage("terminal:ack", {
    terminalId: frame.terminalId, runId: frame.runId, attachmentId: frame.attachmentId, sequence: frame.sequence,
  }));
}

function nextFrame(app: RelayClient, streamId: string, terminalId: string, timeoutMs = 5_000): Promise<any> {
  return app.waitFor(
    (m: any) => m.type === "terminal:frame" && m._streamId === streamId && m.terminalId === terminalId,
    timeoutMs,
  );
}

async function consumeUntilEnded(app: RelayClient, streamId: string, terminalId: string): Promise<any> {
  const deadline = Date.now() + 10_000;
  while (Date.now() < deadline) {
    const message = await app.waitFor((m: any) => m._streamId === streamId && m.terminalId === terminalId &&
      (m.type === "terminal:frame" || (m.type === "terminal:display:status" && m.code === "ENDED")),
      Math.max(1, deadline - Date.now()));
    if (message.type === "terminal:display:status") return message;
    ackFrame(app, streamId, message);
  }
  throw new Error("Terminal did not finish after its final frame was consumed");
}

describe("gate: terminal frame mode", () => {
  let env: TestEnv;
  let streamId: string;

  beforeAll(async () => {
    // History archiving is off by default under NODE_ENV=test (bun test's own
    // default) to keep unrelated suites from leaking an open SQLite handle —
    // this suite means to exercise it, so it opts in explicitly. The agent
    // runs as its own OS process (spawnAgent/Bun.spawn), so the store's file
    // handle lives and dies with that process; env.teardown()'s taskkill is
    // what releases it, not an in-process close call.
    env = await setupTestEnv({ fixtureName: "basic", env: { ANTGRID_TERMINAL_HISTORY_TEST: "1" } });
    streamId = await firstProjectStream(env.app, env.projectId, 10_000);
  }, 60_000);

  afterAll(async () => {
    await env?.teardown();
  });

  test("local and relay viewers receive only independent frames, including after unsubscribe", async () => {
    const terminalId = "frame-no-mix";
    let local: LocalTestClient | null = null;
    try {
      // The split the product actually has is `InboundSource` (loopback vs relay),
      // not two relay apps: a second concurrent phone is a state single-active
      // takeover prevents, so loopback is the only other viewer to test.
      const conn: LocalConnectInfo = (await loopbackControl(env.abDir, {
        id: "connect-no-mix", type: "project:start", projectId: env.projectId,
      })).connect;
      const localSeen: any[] = [];
      local = new LocalTestClient();
      local.on((m) => {
        localSeen.push(m);
        if (m.type === "terminal:frame") local?.send(createMessage("terminal:ack", {
          terminalId: m.terminalId, runId: m.runId,
          attachmentId: m.attachmentId, sequence: m.sequence,
        }));
      });
      await local.connect(conn);

      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "process.stdin.once('data', () => { let i=0; setInterval(()=>process.stdout.write('TICK_'+(i++)+'\\n'), 20); });",
      ]);
      const relaySubscription = await subscribeFrames(env.app, streamId, terminalId);
      local.send(createMessage("terminal:subscribe", {
        terminalId, version: TERMINAL_PROTOCOL_VERSION, requestId: "local-frame-subscribe",
      }));
      // CR, not LF: the PTY's line discipline holds a typed line until Enter, so
      // "go\n" is echoed to the screen and never handed to the guest's stdin —
      // which leaves the guest silent and every assertion below unexercised.
      env.app.sendOnStream(streamId, createMessage("terminal:input", { terminalId, data: "go\r" }));

      // The guest's OWN bytes, not merely a frame: subscribing produces a frame
      // of the blank starting screen, so a row that counts frames alone is
      // satisfied by a guest that never ran and measures no suppression at all.
      let tickFrames = 0;
      const tickDeadline = Date.now() + 15_000;
      while (Date.now() < tickDeadline && tickFrames === 0) {
        const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
        if (!frame) continue;
        if (String(frame.ansi).includes("TICK_")) tickFrames++;
        ackFrame(env.app, streamId, frame);
      }
      expect(tickFrames).toBeGreaterThan(0);

      // Only now is the suppression window measured: the guest is demonstrably
      // writing throughout it, so a `terminal:output` withheld here is withheld
      // from live traffic rather than from silence.
      const deadline = Date.now() + 1_500;
      while (Date.now() < deadline) {
        const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
        if (frame) ackFrame(env.app, streamId, frame);
      }
      expect(env.app.queuedCount((m: any) => m.type === "terminal:output" && m.terminalId === terminalId)).toBe(0);

      expect(localSeen.some((m: any) =>
        m.type === "terminal:frame" && m.terminalId === terminalId && String(m.ansi).includes("TICK_"),
      )).toBe(true);
      expect(localSeen.some((m: any) => m.type === "terminal:output" || m.type === "terminal:snapshot")).toBe(false);
      // Both encrypted transports share one grid, but only explicit takeover
      // transfers its ownership. A delayed old-owner resize must be harmless.
      for (const [clientId, cols, rows] of [["local-owner", 96, 28], ["remote-owner", 48, 16]] as const) {
        const takeover = createMessage("terminal:resize", { terminalId, clientId, cols, rows, intent: "takeover" });
        if (clientId === "local-owner") local.send(takeover);
        else env.app.sendOnStream(streamId, takeover);
        await env.app.waitFor((m: any) => m.type === "terminal:size" && m.terminalId === terminalId &&
          m.driverClientId === clientId && m.cols === cols && m.rows === rows, 5_000);
        let matched = false;
        const until = Date.now() + 5_000;
        while (!matched && Date.now() < until) {
          const frame = await nextFrame(env.app, streamId, terminalId);
          ackFrame(env.app, streamId, frame);
          matched = frame.cols === cols && frame.rows === rows;
        }
        expect(matched).toBe(true);
      }
      local.send(createMessage("terminal:resize", {
        terminalId, clientId: "local-owner", cols: 96, rows: 28,
        baseDriverClientId: "remote-owner", intent: "resize",
      }));
      const retained = await env.app.waitFor((m: any) => m.type === "terminal:size" &&
        m.terminalId === terminalId && m.driverClientId === "remote-owner", 5_000);
      expect([retained.cols, retained.rows]).toEqual([48, 16]);
      expect(localSeen.some((m: any) => m.type === "terminal:frame" && m.cols === 48 && m.rows === 16)).toBe(true);
      env.app.sendOnStream(streamId, createMessage("terminal:unsubscribe", {
        terminalId, runId: relaySubscription.runId, attachmentId: relaySubscription.attachmentId,
      }));
      await Bun.sleep(300);
      expect(env.app.queuedCount((m: any) => m.terminalId === terminalId &&
        (m.type === "terminal:output" || m.type === "terminal:snapshot"))).toBe(0);
    } finally {
      local?.close();
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 30_000);

  test("a missing terminal receives a correlated refusal over the encrypted project stream", async () => {
    const requestId = crypto.randomUUID();
    env.app.sendOnStream(streamId, createMessage("terminal:subscribe", {
      terminalId: "frame-never-existed", version: TERMINAL_PROTOCOL_VERSION, requestId,
    }));
    const refusal = await env.app.waitFor((m: any) =>
      m.type === "terminal:display:status" && m._streamId === streamId && m.requestId === requestId,
      5_000);
    expect(refusal.code).toBe("UNKNOWN_TERMINAL");
    expect(refusal.attachmentId).toBeUndefined();
    expect(refusal.terminalId).toBe("frame-never-existed");
  });

  test("an unsupported terminal version requires an upgrade and never starts raw delivery", async () => {
    const terminalId = "frame-upgrade-required";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "setInterval(() => console.log('UNSUPPORTED_OUTPUT'), 20);",
      ]);
      const requestId = crypto.randomUUID();
      env.app.sendOnStream(streamId, createMessage("terminal:subscribe", {
        terminalId, version: TERMINAL_PROTOCOL_VERSION + 1, requestId,
      }));
      const status = await env.app.waitFor((m: any) =>
        m.type === "terminal:display:status" && m._streamId === streamId && m.requestId === requestId,
      5_000);
      expect(status.code).toBe("UPGRADE_REQUIRED");
      await Bun.sleep(300);
      expect(env.app.queuedCount((m: any) => m.terminalId === terminalId &&
        ["terminal:output", "terminal:snapshot", "terminal:frame"].includes(m.type))).toBe(0);
    } finally {
      env.app.sendOnStream(streamId, createMessage("terminal:stop", { terminalId }));
      await env.app.waitFor((m: any) => m.type === "terminal:exited" &&
        m._streamId === streamId && m.terminalId === terminalId, 10_000);
    }
  }, 20_000);

  test("frames delivered to a subscribed viewer are capped at 20 per second under sustained, gap-free output", async () => {
    const terminalId = "frame-rate-cap";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "let i=0; setInterval(()=>process.stdout.write('R'.repeat(120)+(i++)+'\\n'), 2);",
      ]);
      await subscribeFrames(env.app, streamId, terminalId);

      // 20 FPS is the plan's hard gate ("maximum 20 captures and sends per
      // second"), so the allowance below is computed from that number and the
      // constant is pinned to it separately. Deriving the allowance from the
      // constant alone would make the row self-referential: halve
      // TERMINAL_FRAME_INTERVAL_MS and both the delivered rate and the
      // allowance double, and the gate the plan states would go unwatched.
      const gateFramesPerSecond = 20;
      expect(1_000 / TERMINAL_FRAME_INTERVAL_MS).toBe(gateFramesPerSecond);

      const windowMs = 2_000;
      const start = Date.now();
      let count = 0;
      while (Date.now() - start < windowMs) {
        // A missed slot is data, not a failure. This row measures an UPPER
        // bound, so a delivery gap only lowers the count while raising the
        // allowance — but a bare wait would turn that same gap into a red row.
        const frame = await nextFrame(env.app, streamId, terminalId, 250).catch(() => null);
        if (!frame) continue;
        count++;
        ackFrame(env.app, streamId, frame);
      }
      const elapsed = Date.now() - start;
      // +2 covers a boundary frame at each end of the measured window plus
      // scheduler jitter, without hiding a real regression (a doubled rate
      // would still fail this by a wide margin).
      const maxAllowed = Math.ceil((elapsed * gateFramesPerSecond) / 1_000) + 2;
      expect(count).toBeGreaterThan(0);
      expect(count).toBeLessThanOrEqual(maxAllowed);
      // Only the DELIVERED rate is observable from out here, which is why the
      // title claims no more: the capture throttle and the sender's pacing sit
      // in series on the same interval, and a frame is sent at most once per
      // capture, so deleting either one alone changes nothing on this wire.
      // The capture half has its own gate in the bridge suite —
      // bridge/tests/terminal-frame-delivery.test.ts, "a capture the source
      // refuses is still charged against the frame interval".
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 30_000);

  test("the last frame before a natural exit reflects the true final output, including a write on the exiting tick, and ENDED carries the exit code", async () => {
    const terminalId = "frame-exit-final";
    const marker = `DONE_${Date.now()}`;
    // The marker is written on the SAME tick that calls process.exit, which is
    // the whole point: a marker written seconds earlier rides every frame from
    // the first capture onward, so the row would pass on a pipeline that
    // emitted one frame at subscribe time and then never ticked again. BOOT
    // gives that early, marker-less screen something to show, so the assertion
    // below has to be satisfied by the FINAL capture (`TerminalFrameHub.finish`
    // settling the parser, then raising `finalRevision`) and by nothing else.
    await startTerminal(env.app, streamId, terminalId, "node", [
      "-e", `console.log('BOOT'); setTimeout(() => { console.log('${marker}'); process.exit(0); }, 1400);`,
    ]);
    await subscribeFrames(env.app, streamId, terminalId);

    let lastFrame: any = null;
    let framesBeforeMarker = 0;
    let ended: any = null;
    const deadline = Date.now() + 15_000;
    while (Date.now() < deadline && !ended) {
      const msg = await env.app.waitFor(
        (m: any) => m._streamId === streamId && m.terminalId === terminalId &&
          (m.type === "terminal:frame" || (m.type === "terminal:display:status" && m.code === "ENDED")),
        500,
      ).catch(() => null);
      if (!msg) continue;
      if (msg.type === "terminal:frame") {
        if (!String(msg.ansi).includes(marker)) framesBeforeMarker++;
        lastFrame = msg;
        ackFrame(env.app, streamId, msg);
      } else ended = msg;
    }

    expect(ended).not.toBeNull();
    expect(ended.exitCode).toBe(0);
    expect(lastFrame).not.toBeNull();
    expect(framesBeforeMarker).toBeGreaterThan(0);
    expect(lastFrame.ansi).toContain(marker);
    // ENDED is the LAST thing this attachment ever gets: the hub raises it only
    // once the final frame has been both sent and acked. So `lastFrame` above is
    // the screen the pane is left showing, with nothing behind it — a frame
    // arriving after ENDED would mean the app had already torn the pane's
    // attachment down and would never draw the real final screen.
    await new Promise((r) => setTimeout(r, 300));
    expect(env.app.queuedCount((m: any) =>
      m.type === "terminal:frame" && m._streamId === streamId && m.terminalId === terminalId,
    )).toBe(0);
  }, 30_000);

  test("terminal:exited, terminal:notification and terminal:bell reach a frame-mode viewer", async () => {
    const terminalId = "frame-lifecycle-events";
    // Events are raised after the subscribe has certainly landed, so this
    // is about what a frame-mode viewer keeps receiving — not about what was
    // already in flight when it switched modes. A frame viewer has no other
    // way to learn its terminal exited or asked for attention: the hub raises
    // ENDED, and nothing else.
    await startTerminal(env.app, streamId, terminalId, "node", [
      "-e", "setTimeout(() => process.stdout.write('\\x1b]9;FRAME_NOTIFY\\x07\\x07'), 700); setTimeout(() => process.exit(3), 1400);",
    ]);
    const subscription = await subscribeFrames(env.app, streamId, terminalId);

    const notification = await env.app.waitFor(
      (m: any) => m.type === "terminal:notification" && m._streamId === streamId && m.terminalId === terminalId,
      10_000,
    );
    expect(notification.kind).toBe("osc9");
    expect(notification.body).toContain("FRAME_NOTIFY");

    const bell = await env.app.waitFor(
      (m: any) => m.type === "terminal:bell" && m._streamId === streamId && m.terminalId === terminalId,
      10_000,
    );
    expect(bell.runId).toBe(subscription.runId);
    expect(bell.checkoutId).toBe("main");

    const exited = await env.app.waitFor(
      (m: any) => m.type === "terminal:exited" && m._streamId === streamId && m.terminalId === terminalId,
      10_000,
    );
    expect(exited.exitCode).toBe(3);
  }, 30_000);

  test("a client-initiated stop retains the last frame's content, and ENDED follows", async () => {
    const terminalId = "frame-stop-retain";
    const marker = `STOP_MARK_${Date.now()}`;
    // The stop this row is about is also its cleanup, so the `finally` below
    // only has work to do when an assertion threw BEFORE the stop went out.
    let stopRequested = false;
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", `console.log('${marker}'); setInterval(() => {}, 60000);`,
      ]);
      await subscribeFrames(env.app, streamId, terminalId);

      let lastFrame: any = null;
      const deadline = Date.now() + 5_000;
      while (Date.now() < deadline) {
        const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
        if (!frame) continue;
        lastFrame = frame;
        ackFrame(env.app, streamId, frame);
        if (frame.ansi.includes(marker)) break;
      }
      expect(lastFrame?.ansi).toContain(marker);

      env.app.sendOnStream(streamId, createMessage("terminal:stop", { terminalId }));
      stopRequested = true;
      const ended = await env.app.waitFor(
        (m: any) => m.type === "terminal:display:status" && m._streamId === streamId &&
          m.terminalId === terminalId && m.code === "ENDED",
        10_000,
      );
      expect(ended.attachmentId).toBe(lastFrame.attachmentId);
      // Nothing that superseded the marker frame ever arrived without the
      // marker still in it — stopping must not blank or corrupt the display.
      expect(env.app.queuedCount((m: any) =>
        m.type === "terminal:frame" && m._streamId === streamId &&
        m.terminalId === terminalId && !String(m.ansi).includes(marker),
      )).toBe(0);
    } finally {
      if (!stopRequested) await stopTerminal(env.app, streamId, terminalId);
    }
  }, 20_000);

  test("two terminals resized to different geometries never cross-deliver frames, geometry or screen content", async () => {
    const idA = "frame-size-a";
    const idB = "frame-size-b";
    try {
      // Distinct multi-character markers, not the bare letters: a single "A" or
      // "B" occurs inside the escape sequences a serialized screen is dense with
      // (CUD is `CSI B`), so a one-letter probe would be satisfied by punctuation.
      await startTerminal(env.app, streamId, idA, "node", ["-e", "setInterval(()=>process.stdout.write('ALPHA_ROW\\n'), 20);"]);
      resizeTerminal(env.app, streamId, idA, 60, 18);
      await startTerminal(env.app, streamId, idB, "node", ["-e", "setInterval(()=>process.stdout.write('BRAVO_ROW\\n'), 20);"]);
      resizeTerminal(env.app, streamId, idB, 110, 40);

      const subA = await subscribeFrames(env.app, streamId, idA);
      const subB = await subscribeFrames(env.app, streamId, idB);

      // A resize is queued behind the frame source's own parser write (see the
      // comment on `TerminalFrameSource.resize` in bridge/src/terminal-frames/
      // source.ts) — there is no ack for it, so a subscribe made immediately
      // after can legitimately observe one stale capture before it lands. The
      // same is true of content: the first captures land while node is still
      // starting up and show an empty screen. Drain until each terminal is both
      // at its geometry and actually printing, so this test is about
      // cross-delivery, not about resize or process-start latency.
      async function waitForSettled(terminalId: string, cols: number, rows: number, marker: string): Promise<void> {
        const settleDeadline = Date.now() + 8_000;
        while (Date.now() < settleDeadline) {
          const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
          if (!frame) continue;
          ackFrame(env.app, streamId, frame);
          if (frame.cols === cols && frame.rows === rows && String(frame.ansi).includes(marker)) return;
        }
        throw new Error(`terminal ${terminalId} never converged to ${cols}x${rows} showing ${marker}`);
      }
      await waitForSettled(idA, 60, 18, "ALPHA_ROW");
      await waitForSettled(idB, 110, 40, "BRAVO_ROW");

      const deadline = Date.now() + 2_000;
      let seenA = 0;
      let seenB = 0;
      while (Date.now() < deadline) {
        const frame = await env.app.waitFor(
          (m: any) => m.type === "terminal:frame" && m._streamId === streamId &&
            (m.terminalId === idA || m.terminalId === idB),
          500,
        ).catch(() => null);
        if (!frame) continue;
        if (frame.terminalId === idA) {
          expect(frame.cols).toBe(60);
          expect(frame.rows).toBe(18);
          expect(frame.runId).toBe(subA.runId);
          expect(frame.ansi).toContain("ALPHA_ROW");
          expect(frame.ansi).not.toContain("BRAVO_ROW");
          seenA++;
        } else {
          expect(frame.cols).toBe(110);
          expect(frame.rows).toBe(40);
          expect(frame.runId).toBe(subB.runId);
          expect(frame.ansi).toContain("BRAVO_ROW");
          expect(frame.ansi).not.toContain("ALPHA_ROW");
          seenB++;
        }
        ackFrame(env.app, streamId, frame);
      }
      expect(seenA).toBeGreaterThan(0);
      expect(seenB).toBeGreaterThan(0);
    } finally {
      await stopTerminal(env.app, streamId, idA);
      await stopTerminal(env.app, streamId, idB);
    }
  }, 30_000);

  test("paging terminal:history:request backwards across multiple pages reconstructs every scrolled-off row, ascending within each page and across the merge, exactly once", async () => {
    const terminalId = "frame-history";
    try {
      const total = TERMINAL_HISTORY_PAGE_ROWS * 2; // more than one page, with the live screen's worth to spare
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", `for (let i = 0; i < ${total}; i++) console.log('LINE_' + i); setInterval(() => {}, 60000);`,
      ]);
      const { runId, attachmentId } = await subscribeFrames(env.app, streamId, terminalId);

      // Wait for the boundary restated on each frame to show MORE than a full
      // page archived, rather than for a stretch of wall clock: the multi-page
      // assertions below are about paging, and a fixed sleep makes them about
      // how far the guest and the archiver got through the burst first.
      let boundary: any = null;
      const boundaryDeadline = Date.now() + 12_000;
      while (Date.now() < boundaryDeadline) {
        const frame = await nextFrame(env.app, streamId, terminalId, 1_000).catch(() => null);
        if (!frame) continue;
        boundary = frame.history;
        ackFrame(env.app, streamId, frame);
        if (boundary.nextRowId > TERMINAL_HISTORY_PAGE_ROWS) break;
      }
      expect(boundary).not.toBeNull();
      expect(boundary.nextRowId).toBeGreaterThan(TERMINAL_HISTORY_PAGE_ROWS);

      const rows: Array<{ rowId: number; text: string }> = [];
      let cursor = boundary.nextRowId;
      let pages = 0;
      while (cursor > boundary.firstRowId) {
        const requestId = crypto.randomUUID();
        env.app.sendOnStream(streamId, createMessage("terminal:history:request", {
          terminalId, runId, attachmentId, requestId, epoch: boundary.epoch, beforeRowId: cursor,
        }));
        const page = await env.app.waitFor(
          (m: any) => m.type === "terminal:history:page" && m._streamId === streamId && m.requestId === requestId,
          10_000,
        );
        expect(page.expired).toBe(false);
        expect(page.rows.length).toBeGreaterThan(0);
        // Order WITHIN a page is the clause the Dart renderer relies on to lay a
        // page out without re-sorting it, so it is asserted before the merge —
        // sorting the pooled rows first would cover it only by accident.
        for (let i = 0; i < page.rows.length; i++) {
          const row = page.rows[i];
          if (i > 0) expect(row.rowId).toBe(page.rows[i - 1].rowId + 1);
          // `wrapped` means "this row continues the one above". Every LINE_n is
          // far shorter than the screen, so a true here would mean the archive
          // is inventing continuations the renderer would then splice together.
          expect(row.wrapped).toBe(false);
        }
        // The cursor is EXCLUSIVE, and the page starts immediately below it:
        // the newest row here is `cursor - 1`. An inclusive read would repeat
        // the row the previous page already carried, which the merge below
        // would then see as a duplicate — but only after the whole archive had
        // been paged, and only for a run long enough to have a previous page.
        // Asserting it per page names the defect at the page that has it.
        expect(page.rows[page.rows.length - 1].rowId).toBe(cursor - 1);
        // `page.beforeRowId` is the server's own cursor for the next, older
        // page, and is taken on trust here rather than asserted — it is
        // computed FROM `rows[0]`, so comparing the two could not fail. A wrong
        // one shows up as a gap or a duplicate in the merged run below.
        //
        // Each page is older than the one before it, so prepending reconstructs
        // the archive in scroll-off order with no sort anywhere in the test.
        rows.unshift(...page.rows.map((row: any) => ({
          rowId: row.rowId, text: row.spans.map((s: any) => s.text).join("").trimEnd(),
        })));
        cursor = page.beforeRowId;
        pages++;
      }
      // Every page but the oldest comes back FULL, so the archived span fixes
      // the page count exactly. `>= 2` is satisfied by a server that returns
      // the same rows in twice as many half-size pages.
      expect(pages).toBe(Math.ceil((boundary.nextRowId - boundary.firstRowId) / TERMINAL_HISTORY_PAGE_ROWS));

      const rowIds = rows.map((r) => r.rowId);
      expect(new Set(rowIds).size).toBe(rowIds.length); // no duplicate
      for (let i = 0; i < rowIds.length; i++) expect(rowIds[i]).toBe(boundary.firstRowId + i); // no gap, ascending
      // rowId k IS print index k: the archive orders rows exactly as they
      // scrolled off (oldest first), starting a fresh run with nothing archived.
      for (const row of rows) expect(row.text).toBe(`LINE_${row.rowId}`);
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 45_000);

  test("a CSI 3J history clear turns the epoch over, and a request against the epoch before it comes back expired with a boundary paging can restart from", async () => {
    const terminalId = "frame-history-expired";
    try {
      // The clear is driven the way the field reaches it — the guest emitting
      // CSI 3J, which `TerminalFrameSource`'s own parser handler turns into
      // `clearHistory()` and an epoch bump. Handing the request a fabricated
      // `epoch + 1` reaches the same `expired` branch while testing none of that
      // wiring. The POST_ lines after the clear push live rows off the top
      // again, so the fresh epoch has something to page.
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "for (let i = 0; i < 60; i++) console.log('E_LINE_' + i);"
          + " setTimeout(() => { process.stdout.write('\\x1b[3J');"
          + " for (let i = 0; i < 10; i++) console.log('POST_' + i); }, 2500);"
          + " setInterval(() => {}, 60000);",
      ]);
      const { runId, attachmentId } = await subscribeFrames(env.app, streamId, terminalId);

      let boundary: any = null;
      const deadline = Date.now() + 5_000;
      while (Date.now() < deadline) {
        const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
        if (!frame) continue;
        ackFrame(env.app, streamId, frame);
        if (frame.history.epoch === 0 && frame.history.nextRowId > 0) { boundary = frame.history; break; }
      }
      expect(boundary).not.toBeNull();

      // The turnover is observed on the wire before anything is asked of it: the
      // boundary restated on every frame is how the app learns its cursors died.
      let turnedOver: any = null;
      const clearDeadline = Date.now() + 10_000;
      while (Date.now() < clearDeadline) {
        const frame = await nextFrame(env.app, streamId, terminalId, 3_000).catch(() => null);
        if (!frame) continue;
        ackFrame(env.app, streamId, frame);
        if (frame.history.epoch > boundary.epoch) { turnedOver = frame.history; break; }
      }
      expect(turnedOver).not.toBeNull();
      expect(turnedOver.epoch).toBe(boundary.epoch + 1);

      const badRequestId = crypto.randomUUID();
      env.app.sendOnStream(streamId, createMessage("terminal:history:request", {
        terminalId, runId, attachmentId, requestId: badRequestId,
        epoch: boundary.epoch, beforeRowId: boundary.nextRowId,
      }));
      const expiredPage = await env.app.waitFor(
        (m: any) => m.type === "terminal:history:page" && m._streamId === streamId && m.requestId === badRequestId,
        10_000,
      );
      expect(expiredPage.expired).toBe(true);
      expect(expiredPage.rows).toHaveLength(0);
      expect(expiredPage.history.epoch).toBe(turnedOver.epoch);

      // Paging restarts cleanly from the boundary the expired reply carried.
      const retryRequestId = crypto.randomUUID();
      env.app.sendOnStream(streamId, createMessage("terminal:history:request", {
        terminalId, runId, attachmentId, requestId: retryRequestId,
        epoch: expiredPage.history.epoch, beforeRowId: expiredPage.history.nextRowId,
      }));
      const goodPage = await env.app.waitFor(
        (m: any) => m.type === "terminal:history:page" && m._streamId === streamId && m.requestId === retryRequestId,
        10_000,
      );
      expect(goodPage.expired).toBe(false);
      expect(goodPage.rows.length).toBeGreaterThan(0);
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 40_000);

  test("a same-id respawn mints a fresh runId: the old run's frames stop arriving and the new run's history starts at epoch 0", async () => {
    const terminalId = "frame-respawn";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", ["-e", "setInterval(() => {}, 60000);"]);
      const sub1 = await subscribeFrames(env.app, streamId, terminalId);
      const runId1 = sub1.runId;
      ackFrame(env.app, streamId, await nextFrame(env.app, streamId, terminalId));

      env.app.sendOnStream(streamId, createMessage("terminal:stop", { terminalId }));
      const ended = await consumeUntilEnded(env.app, streamId, terminalId);
      expect(ended.runId).toBe(runId1);
      // Drop whatever generation-1 frame(s) are still queued (e.g. the initial
      // blank-screen frame from subscribing) so the final leak check below only
      // catches frames that arrive AFTER this point.
      env.app.drainQueued("terminal:frame");

      await startTerminal(env.app, streamId, terminalId, "node", ["-e", "setInterval(() => {}, 60000);"]);
      const sub2 = await subscribeFrames(env.app, streamId, terminalId);
      const runId2 = sub2.runId;
      expect(runId2).not.toBe(runId1);

      const frame2 = await nextFrame(env.app, streamId, terminalId, 5_000);
      expect(frame2.runId).toBe(runId2);
      // An archive that has given up reports the same all-zero boundary as a
      // genuinely fresh run, so the zeros below only mean "fresh" alongside
      // this. Asserted first: it is the one that says the other three are
      // about a new run rather than about a dead store.
      expect(frame2.history.status).toBe("recording");
      expect(frame2.history.epoch).toBe(0);
      expect(frame2.history.firstRowId).toBe(0);
      expect(frame2.history.nextRowId).toBe(0);
      ackFrame(env.app, streamId, frame2);

      await new Promise((r) => setTimeout(r, 300));
      expect(env.app.queuedCount((m: any) =>
        m.type === "terminal:frame" && m._streamId === streamId &&
        m.terminalId === terminalId && m.runId === runId1,
      )).toBe(0);
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 30_000);

  test("a stalled consumer is capped at TERMINAL_VIEWER_MAX_FRAMES in flight and coalesces on catch-up rather than draining a backlog", async () => {
    const terminalId = "frame-stall";
    try {
      await startTerminal(env.app, streamId, terminalId, "node", [
        "-e", "let i=0; setInterval(() => process.stdout.write('S'.repeat(100) + (i++) + '\\n'), 5);",
      ]);
      await subscribeFrames(env.app, streamId, terminalId);

      // The shipped cap written out, and the constant pinned to it separately.
      // An allowance read from TERMINAL_VIEWER_MAX_FRAMES would follow the
      // constant: doubling the cap would double the allowance, and the number
      // in this row's title would go unwatched.
      const gateMaxInFlight = 4;
      expect(TERMINAL_VIEWER_MAX_FRAMES).toBe(gateMaxInFlight);

      const queuedFrames = () => env.app.queuedCount((m: any) =>
        m.type === "terminal:frame" && m._streamId === streamId && m.terminalId === terminalId,
      );
      // Never ack. The cap is an EQUALITY: delivery must REACH four in flight
      // and then stay there while the guest keeps writing. A one-sided `<=`
      // stays green on a cap that binds at three — under-delivery is the half
      // of this gate a bound can silently drop.
      //
      // Waiting for the count to ARRIVE, rather than for it to stop changing,
      // is also what keeps a slow first frame from reading as a stalled one: a
      // loop seeded with the count at entry sees no change and exits at zero.
      const capDeadline = Date.now() + 4_500;
      while (queuedFrames() < gateMaxInFlight && Date.now() < capDeadline) await Bun.sleep(50);
      // The settle window also dates the newest queued frame: it was captured at
      // least this long ago, which is what leaves the catch-up jump below
      // something to measure. Both waits together stay inside
      // TERMINAL_ACK_TIMEOUT_MS, which runs from the first unacked send — the
      // attachment has to outlive the stall to serve the catch-up.
      await Bun.sleep(2_000);
      const stalledFrames = queuedFrames();
      expect(stalledFrames).toBe(gateMaxInFlight);

      // The highest revision the cap let through, taken as a max because
      // nothing in this row asserts the order these frames were queued in.
      let lastRevision = -1;
      let drained = 0;
      const drainDeadline = Date.now() + 2_000;
      while (drained < stalledFrames && Date.now() < drainDeadline) {
        const frame = await nextFrame(env.app, streamId, terminalId, 500).catch(() => null);
        if (!frame) continue;
        drained++;
        lastRevision = Math.max(lastRevision, frame.revision);
        ackFrame(env.app, streamId, frame);
      }
      expect(drained).toBe(stalledFrames);

      // With the backlog acked, delivery resumes. The source ran on through the
      // silence above, so a connection that queued one frame per revision it
      // stalled through would resume a handful of revisions past `lastRevision`;
      // coalescing jumps straight to whatever is current.
      const freshFrame = await nextFrame(env.app, streamId, terminalId, 3_000);
      expect(freshFrame.revision).toBeGreaterThan(lastRevision + gateMaxInFlight);
    } finally {
      await stopTerminal(env.app, streamId, terminalId);
    }
  }, 30_000);
});
