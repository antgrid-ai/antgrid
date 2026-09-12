// Wave 5: delivery.ts had zero coverage before this file. Two layers —
// `describe("hub", ...)` drives `TerminalFrameHub`/`TerminalViewerConnection`
// directly with a fake clock, so ack-timeout and multi-tick scenarios run in
// milliseconds of real time; `describe("wiring", ...)` goes through a real
// `AgentCore` + `MessageBus`, proving the pieces THIS wave actually built
// (hub registration off `TerminalManager`'s own run id, the four inbound
// cases, mode exclusivity, connection teardown) rather than delivery.ts's
// pre-existing, already-correct internals.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { buildAgentCore, type AgentCore } from "../src/agent-core";
import { closeTerminalHistoryStore } from "../src/terminal-manager";
import { MessageBus } from "../src/message-bus";
import { createMessage, type AbMessage, type TerminalDisplayStatus, type TerminalFrame } from "../src/protocol";
import { setLogLevel } from "../src/logger";
import {
  TerminalFrameHub, type TerminalAddress, type TerminalViewerTransport,
} from "../src/terminal-frames/delivery";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import {
  TERMINAL_ACK_TIMEOUT_MS, TERMINAL_FRAME_INTERVAL_MS, TERMINAL_PROTOCOL_VERSION,
  TERMINAL_VIEWER_MAX_FRAMES,
} from "../src/terminal-frames/protocol";

setLogLevel("error");

// --- describe("hub"): direct delivery.ts coverage, fake clock -------------

const sources: TerminalFrameSource[] = [];
function source(cols = 40, rows = 6): TerminalFrameSource {
  const screen = new TerminalFrameSource(cols, rows);
  sources.push(screen);
  return screen;
}
afterEach(() => {
  for (const screen of sources.splice(0)) screen.dispose();
});

function addr(terminalId = "t1"): TerminalAddress {
  return { projectId: "p", checkoutId: "main", terminalId };
}

async function paint(screen: TerminalFrameSource, text: string): Promise<void> {
  screen.feed(text);
  await screen.settle();
}

/** Every cell distinctly coloured — the JSON-encoded byte count `capture()`
 *  measures diverges hardest from the raw ANSI here, which is how a screen
 *  well under 300x180's raw byte count still trips `TERMINAL_FRAME_MAX_ANSI_BYTES`.
 *  Mirrors `paintDense` in terminal-frame-source.test.ts (private there). */
async function paintDense(screen: TerminalFrameSource, cols: number, rows: number): Promise<void> {
  for (let row = 0; row < rows; row++) {
    let line = `\x1b[${row + 1};1H`;
    for (let col = 0; col < cols; col++) line += `\x1b[38;2;${10 + ((row + col) % 2)};20;30m#`;
    screen.feed(line);
    await screen.settle();
  }
}

class FakeTransport implements TerminalViewerTransport {
  sent: (TerminalFrame | TerminalDisplayStatus | AbMessage)[] = [];
  retirements: string[] = [];
  allowed = true;
  authorized(): boolean {
    return this.allowed;
  }
  retired(_address: TerminalAddress, attachmentId: string): void {
    this.retirements.push(attachmentId);
  }
  async send(message: TerminalFrame | TerminalDisplayStatus | AbMessage, signal: AbortSignal): Promise<void> {
    if (signal.aborted) return;
    this.sent.push(message);
  }
}

/** TS-1's exact failure shape: `send` is a PLAIN function, not `async`, so a
 *  `throw` inside it raises SYNCHRONOUSLY out of the call expression itself,
 *  before any promise exists for a bare `.catch()` to attach to. An `async`
 *  method here would swallow the throw into a rejected promise instead and
 *  miss the bug entirely — see `safeSend`'s own doc in delivery.ts. */
class ThrowOnceTransport implements TerminalViewerTransport {
  sent: (TerminalFrame | TerminalDisplayStatus | AbMessage)[] = [];
  throwNext = false;
  authorized(): boolean {
    return true;
  }
  send(message: TerminalFrame | TerminalDisplayStatus | AbMessage, signal: AbortSignal): Promise<void> {
    if (this.throwNext) {
      this.throwNext = false;
      throw new Error("synchronous transport failure");
    }
    if (signal.aborted) return Promise.resolve();
    this.sent.push(message);
    return Promise.resolve();
  }
}

function frames(t: { sent: (TerminalFrame | TerminalDisplayStatus | AbMessage)[] }): TerminalFrame[] {
  return t.sent.filter((m): m is TerminalFrame => m.type === "terminal:frame");
}
function statuses(t: { sent: (TerminalFrame | TerminalDisplayStatus | AbMessage)[] }): TerminalDisplayStatus[] {
  return t.sent.filter((m): m is TerminalDisplayStatus => m.type === "terminal:display:status");
}

describe("hub", () => {
  test("register passes the caller's run id straight through — no hub-minted default", () => {
    const hub = new TerminalFrameHub(() => 0);
    const runId = crypto.randomUUID();
    hub.register(addr(), source(), runId);
    expect(hub.find(addr())?.runId).toBe(runId);
  });

  test("a respawn's register replaces the run in place, and a late finish for the OLD run cannot touch the replacement", async () => {
    const hub = new TerminalFrameHub(() => 0);
    const run1 = crypto.randomUUID();
    hub.register(addr(), source(), run1);
    const run2 = crypto.randomUUID();
    hub.register(addr(), source(), run2); // same-id respawn: register() itself removes run1 first
    expect(hub.find(addr())?.runId).toBe(run2);

    // The old run's exit lands late (its tree took longer to reap) and tries
    // to finish a run id this address no longer holds.
    await hub.finish(addr(), run1, 0);
    expect(hub.find(addr())?.runId).toBe(run2);
    expect(hub.find(addr())?.exitCode).toBeUndefined();
  });

  test("two viewers of different speeds stay isolated: one keeps advancing, the other's queue never exceeds the cap", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    hub.register(addr(), screen, crypto.randomUUID());

    const fast = new FakeTransport();
    const slow = new FakeTransport();
    const connFast = hub.connect(fast);
    const connSlow = hub.connect(slow);
    const attFast = await connFast.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    const attSlow = await connSlow.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attFast).toBeDefined();
    expect(attSlow).toBeDefined();
    expect(attFast).not.toBe(attSlow);
    const runId = hub.find(addr())!.runId;

    for (let i = 0; i < 10; i++) {
      await paint(screen, `line ${i}\r\n`);
      now += TERMINAL_FRAME_INTERVAL_MS + 10;
      hub.tick();
      const last = frames(fast).at(-1);
      if (last) connFast.acknowledge(addr(), { runId, attachmentId: attFast!, sequence: last.sequence });
      // slow never acknowledges anything.
    }

    expect(frames(fast).length).toBeGreaterThan(frames(slow).length);
    expect(frames(slow).length).toBeLessThanOrEqual(TERMINAL_VIEWER_MAX_FRAMES);
    // The fast viewer's own delivery was never held up by the slow one.
    expect(frames(fast).length).toBeGreaterThan(TERMINAL_VIEWER_MAX_FRAMES);
  });

  test("a stalled viewer's queue stops growing at the cap, then ACK_TIMEOUT retires it", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    hub.register(addr(), screen, crypto.randomUUID());
    const stalled = new FakeTransport();
    const conn = hub.connect(stalled);
    const attachmentId = await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attachmentId).toBeDefined();

    for (let i = 0; i < 8; i++) {
      await paint(screen, `x${i}\r\n`);
      now += TERMINAL_FRAME_INTERVAL_MS + 10;
      hub.tick();
    }
    expect(frames(stalled).length).toBeLessThanOrEqual(TERMINAL_VIEWER_MAX_FRAMES);

    now += TERMINAL_ACK_TIMEOUT_MS + 10;
    hub.tick();
    expect(statuses(stalled).some((m) => m.code === "ACK_TIMEOUT")).toBe(true);

    // Retired, not merely paused: nothing further is ever queued for it.
    const before = stalled.sent.length;
    await paint(screen, "more\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(stalled.sent.length).toBe(before);
  });

  test("duplicate and impossible-future acks are rejected", async () => {
    const hub = new TerminalFrameHub(() => 0);
    const screen = source();
    const runId = crypto.randomUUID();
    hub.register(addr(), screen, runId);
    const t = new FakeTransport();
    const conn = hub.connect(t);
    const attachmentId = await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    await paint(screen, "hello\r\n");
    hub.tick();
    const frame = frames(t)[0];
    expect(frame).toBeDefined();

    expect(conn.acknowledge(addr(), { runId, attachmentId: attachmentId!, sequence: frame.sequence })).toBe(true);
    expect(conn.acknowledge(addr(), { runId, attachmentId: attachmentId!, sequence: frame.sequence })).toBe(false);
    expect(conn.acknowledge(addr(), { runId, attachmentId: attachmentId!, sequence: frame.sequence + 1000 })).toBe(false);
  });

  test("an oversize screen is reported, repeatedly, without ever retiring the attachment", async () => {
    // A real clock, not a frozen one: `subscribe()` ticks once on its own to
    // push the initial (blank) frame, which claims `lastCapture` at that
    // instant — a frozen `now` would then fail `hub.frame()`'s own throttle
    // (`now - run.lastCapture >= TERMINAL_FRAME_INTERVAL_MS`) forever after
    // and the dense paint below would never actually be captured.
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source(300, 180);
    hub.register(addr(), screen, crypto.randomUUID());
    const t = new FakeTransport();
    const conn = hub.connect(t);
    const attachmentId = await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attachmentId).toBeDefined();
    // subscribe() itself ticks once and sends the initial (blank) capture —
    // irrelevant to this test, which is about the capture AFTER that one.
    t.sent.length = 0;

    await paintDense(screen, 300, 180);
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(screen.oversize).toBe(true);
    expect(frames(t)).toEqual([]);
    expect(statuses(t).some((m) => m.code === "DISPLAY_FAILED")).toBe(true);

    // Still subscribed: a small screen right after resumes normal delivery.
    screen.feed("\x1bc\x1b[Hsmall again");
    await screen.settle();
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(frames(t).length).toBe(1);
  }, 30_000);

  // The revocation edge is `connState.suppressed` (the app backgrounded, the
  // peer briefly offline) far more often than it is a real revocation, and
  // both come back. Retiring here froze the terminal for good: the viewer
  // holds a runId/attachmentId it believes is live, gets no status, and (see
  // the wiring test below) the legacy output stream stays suppressed too.
  test("a refused authorization PAUSES the attachment and drops its queue; re-authorizing resumes delivery", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    hub.register(addr(), screen, crypto.randomUUID());
    const t = new FakeTransport();
    const conn = hub.connect(t);
    const attachmentId = await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attachmentId).toBeDefined();

    await paint(screen, "before\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(frames(t).length).toBeGreaterThan(0);
    expect(conn.unacknowledgedBytes).toBeGreaterThan(0);

    t.allowed = false;
    t.sent.length = 0;
    await paint(screen, "after\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(frames(t)).toEqual([]);
    // "Retire pending viewer work" (D5): nothing is held for a viewer that
    // cannot receive, so the connection's in-flight accounting is released...
    expect(conn.unacknowledgedBytes).toBe(0);
    // ...but the subscription itself survives.
    expect(conn.size).toBe(1);
    expect(conn.hasAttachment(attachmentId!)).toBe(true);

    t.allowed = true;
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    // Resumes with the CURRENT screen even though nothing was painted after
    // the pause — the frames dropped on the pause edge were already counted as
    // delivered, so a viewer that never received them must be resent.
    expect(frames(t).length).toBeGreaterThan(0);
  });

  test("a rebuild re-registering the SAME run id keeps every viewer attached and delivering", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const first = source();
    const runId = crypto.randomUUID();
    hub.register(addr(), first, runId);
    const t = new FakeTransport();
    const conn = hub.connect(t);
    const attachmentId = await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    await paint(first, "before rebuild\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(frames(t).length).toBeGreaterThan(0);

    // Exactly what `TerminalManager.ensureLiveScreen` does when a source
    // latches a parse failure: a NEW emulator for the run the PTY is still
    // running, under the run id the hub already holds.
    const replacement = source();
    t.sent.length = 0;
    hub.register(addr(), replacement, runId);
    expect(conn.size).toBe(1);
    expect(conn.hasAttachment(attachmentId!)).toBe(true);

    await paint(replacement, "after rebuild\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    // The replacement's revisions restart at 0, well below the high-water mark
    // the attachment reached against the old source.
    expect(frames(t).length).toBeGreaterThan(0);
  });

  test("removing a run tells each viewer it ENDED, with the exit code, exactly once", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    hub.register(addr(), screen, crypto.randomUUID());
    const t = new FakeTransport();
    const conn = hub.connect(t);
    await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    await paint(screen, "work\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    t.sent.length = 0;

    hub.remove(addr(), 7);
    const ended = statuses(t).filter((m) => m.code === "ENDED");
    expect(ended.length).toBe(1);
    expect(ended[0].exitCode).toBe(7);
    expect(conn.size).toBe(0);
  });

  test("every retirement the hub performs on its own clock is reported to the transport", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    hub.register(addr(), screen, crypto.randomUUID());
    const t = new FakeTransport();
    const conn = hub.connect(t);
    const attachmentId = await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(t.retirements).toEqual([]);

    await paint(screen, "x\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    now += TERMINAL_ACK_TIMEOUT_MS + 10;
    hub.tick(); // ACK_TIMEOUT: nothing outside this file dispatched anything

    expect(t.retirements).toEqual([attachmentId!]);
    expect(conn.size).toBe(0);
  });

  test("a capture the source refuses is still charged against the frame interval", async () => {
    // `capture()` returns null on three routine paths, and `register()` drives
    // a tick off EVERY parse event — so a throttle that only advanced on a
    // successful capture ran a full screen serialization per parse.
    let now = 0;
    let captures = 0;
    class CountingSource extends TerminalFrameSource {
      override capture(at: number): ReturnType<TerminalFrameSource["capture"]> {
        captures++;
        return super.capture(at);
      }
    }
    const screen = new CountingSource(80, 24);
    sources.push(screen);
    const hub = new TerminalFrameHub(() => now);
    hub.register(addr(), screen, crypto.randomUUID());
    const t = new FakeTransport();
    const conn = hub.connect(t);
    await conn.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());

    // Synchronized output: the guest has opened a DECSET 2026 batch, which a
    // TUI can hold for as long as it likes. Every capture inside it returns
    // null.
    await paint(screen, "\x1b[?2026h" + "painting");
    captures = 0;
    for (let i = 0; i < 50; i++) hub.tick(); // 50 parse events at the same instant
    expect(captures).toBeLessThanOrEqual(1);

    // And across a simulated second the interval is the ceiling, not a floor.
    captures = 0;
    for (let i = 0; i < 200; i++) { now += 5; hub.tick(); }
    expect(captures).toBeLessThanOrEqual(1000 / TERMINAL_FRAME_INTERVAL_MS);
  });

  // TS-1: send() throwing SYNCHRONOUSLY (before returning a promise) is a real
  // path this drives off a bare setInterval with nothing above it to catch.
  // One bad viewer must not stop delivery to any other viewer.
  test("TS-1: a transport whose send() throws synchronously retires only that attachment; the tick and every other viewer survive", async () => {
    let now = 0;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    hub.register(addr(), screen, crypto.randomUUID());

    const throwing = new ThrowOnceTransport();
    const healthy = new FakeTransport();
    const connThrowing = hub.connect(throwing);
    const connHealthy = hub.connect(healthy);
    const attThrow = await connThrowing.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    const attHealthy = await connHealthy.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attThrow).toBeDefined();
    expect(attHealthy).toBeDefined();

    await paint(screen, "line" + "\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    throwing.throwNext = true;
    healthy.sent.length = 0;

    expect(() => hub.tick()).not.toThrow();
    expect(frames(healthy).length).toBeGreaterThan(0);

    const before = throwing.sent.length;
    await paint(screen, "more" + "\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    expect(throwing.sent.length).toBe(before);
  });
});

// --- describe("wiring"): through a real AgentCore + MessageBus -------------

let root: string;
let previousAbDir: string | undefined;
let core: AgentCore | null;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-terminal-frame-delivery-"));
  process.env.ANTGRID_DIR = join(root, "state");
  // `terminalHistoryStore()` refuses to touch disk under a bare `bun test`
  // run unless a test opts in explicitly — see its own doc in
  // terminal-manager.ts. The history:request wiring test needs the real
  // store open, matching `terminal-manager-history.test.ts`'s pattern.
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  writeFileSync(join(root, "antgrid.yaml"), "name: terminal-frame-delivery\n");
});

afterEach(async () => {
  const dying = core;
  const dir = root;
  const restore = previousAbDir;
  core = null;
  if (restore === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = restore;
  delete process.env.ANTGRID_TERMINAL_HISTORY_TEST;
  try {
    await dying?.shutdown();
  } finally {
    // Closed before the temp dir removal below: a still-open sqlite handle
    // over a file inside `dir` throws EBUSY on Windows.
    closeTerminalHistoryStore();
    rmSync(dir, { recursive: true, force: true });
  }
}, 30_000);

async function waitFor(
  sent: AbMessage[],
  predicate: (message: AbMessage) => boolean,
  what: string,
  timeoutMs = 5000,
): Promise<AbMessage> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const found = sent.find(predicate);
    if (found) return found;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

async function waitUntil(predicate: () => boolean, what: string, timeoutMs = 5000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timed out waiting for ${what}`);
}

/** Two collectors, one per wire, because mode exclusivity and frame delivery
 *  are both AUDIENCE-targeted: `sent` is what the desktop's loopback socket
 *  would receive, `relaySent` what a phone's relay stream would. A single
 *  audience-less collector cannot tell the two apart — it stands in for an
 *  internal fold (work status, push), which by design still sees everything. */
const internalMessages = new WeakMap<MessageBus, AbMessage[]>();

async function expectNoStreamAfterInput(bus: MessageBus, sent: AbMessage[], data: string, source: "loopback" | "relay" = "loopback"): Promise<void> {
  const internal = internalMessages.get(bus)!;
  internal.length = 0;
  bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data }), "control", source);
  // Observing internal output proves the PTY was active while the transport
  // remained frame-only, including when no attachment can deliver a screen.
  await waitFor(internal, (m) => m.type === "terminal:output" && m.terminalId === "adhoc", "internal PTY output");
  await new Promise((resolve) => setTimeout(resolve, 100));
  expect(sent.some((m) => m.type === "terminal:output" || m.type === "terminal:snapshot")).toBe(false);
}

async function bootWithTerminal(): Promise<{ bus: MessageBus; sent: AbMessage[]; relaySent: AbMessage[] }> {
  core = await buildAgentCore({
    folder: root,
    mode: "local",
    identity: { deviceId: "agent", deviceName: "agent", createdAt: new Date().toISOString() },
  });
  const bus = new MessageBus();
  const sent: AbMessage[] = [];
  const relaySent: AbMessage[] = [];
  const internal: AbMessage[] = [];
  internalMessages.set(bus, internal);
  bus.subscribe({ deliver: (message) => internal.push(message) });
  bus.subscribe({ audience: "loopback", deliver: (message) => sent.push(message) });
  bus.subscribe({ audience: "relay", deliver: (message) => relaySent.push(message) });
  core.attachTransport(bus);
  core.onHandshakeComplete();
  await waitFor(sent, (m) => m.type === "agent:status", "agent:status");

  bus.dispatchInbound(
    createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }),
    "control",
    "loopback",
  );
  await waitFor(sent, (m) => m.type === "terminal:started" && m.terminalId === "adhoc", "terminal:started");
  return { bus, sent, relaySent };
}

describe("wiring", () => {
  test("subscribe registers under TerminalManager's own run id: history for it answers, a foreign run id does not", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const subscribeRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: subscribeRequestId }),
      "control",
      "loopback",
    );
    const subscribed = await waitFor(
      sent,
      (m) => m.type === "terminal:subscribed" && m.requestId === subscribeRequestId,
      "terminal:subscribed",
    );
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");
    const { runId, attachmentId } = subscribed;

    const historyRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:history:request", {
        terminalId: "adhoc", runId, attachmentId, requestId: historyRequestId, epoch: 0, beforeRowId: 0,
      }),
      "control",
      "loopback",
    );
    const page = await waitFor(
      sent,
      (m) => m.type === "terminal:history:page" && m.requestId === historyRequestId,
      "terminal:history:page for the real run id",
    );
    expect(page.type).toBe("terminal:history:page");

    // A syntactically valid but foreign run id names no subscription this
    // terminal's current run ever made — dropped, not answered from main's
    // (or anyone else's) history.
    const foreignRequestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:history:request", {
        terminalId: "adhoc", runId: crypto.randomUUID(), attachmentId, requestId: foreignRequestId, epoch: 0, beforeRowId: 0,
      }),
      "control",
      "loopback",
    );
    await new Promise((resolve) => setTimeout(resolve, 300));
    expect(sent.some((m) => m.type === "terminal:history:page" && m.requestId === foreignRequestId)).toBe(false);
  });

  test("unsubscribing stops frames without enabling raw output", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    const subscribed = await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");

    sent.length = 0;
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo hi\r" }), "control", "loopback");
    // Positive control first: the frame-mode stream IS alive for this terminal.
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");
    expect(sent.some((m) => m.type === "terminal:output" && m.terminalId === "adhoc")).toBe(false);

    bus.dispatchInbound(
      createMessage("terminal:unsubscribe", {
        terminalId: "adhoc", runId: subscribed.runId, attachmentId: subscribed.attachmentId,
      }),
      "control",
      "loopback",
    );
    await new Promise((resolve) => setTimeout(resolve, 100));
    sent.length = 0;
    await expectNoStreamAfterInput(bus, sent, "echo bye\r");
    expect(sent.some((m) => m.type === "terminal:frame")).toBe(false);
  });

  test("a dropped connection retires its subscription without enabling raw output", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");

    core!.noteClientGone("loopback");

    sent.length = 0;
    await expectNoStreamAfterInput(bus, sent, "echo back\r");
  });

  test("subscribing to an unknown terminal gets no reply", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "never-existed", version: TERMINAL_PROTOCOL_VERSION, requestId: crypto.randomUUID() }),
      "control",
      "loopback",
    );
    await new Promise((resolve) => setTimeout(resolve, 400));
    expect(sent.filter((m) => m.type === "terminal:subscribed")).toEqual([]);
  });

  test("subscribing from two sources for the same terminal gets two independent attachments", async () => {
    const { bus, sent, relaySent } = await bootWithTerminal();
    sent.length = 0;

    const loopbackRequest = crypto.randomUUID();
    const relayRequest = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: loopbackRequest }),
      "control",
      "loopback",
    );
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: relayRequest }),
      "control",
      "relay",
    );
    const a = await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === loopbackRequest, "loopback subscribed");
    // On the RELAY collector: a subscribe reply answers the wire that asked.
    const b = await waitFor(relaySent, (m) => m.type === "terminal:subscribed" && m.requestId === relayRequest, "relay subscribed");
    if (a.type !== "terminal:subscribed" || b.type !== "terminal:subscribed") throw new Error("unreachable");
    expect(a.attachmentId).not.toBe(b.attachmentId);
    // Same terminal, same run — both subscriptions resolved the same registration.
    expect(a.runId).toBe(b.runId);
  });

  // Everything below covers the one root cause the adversarial pass found in
  // this wiring: mode exclusivity was marked and unmarked off the INBOUND
  // VERBS, so it diverged from the hub's real attachments in both directions.
  // The marks now follow `subscribe`'s reported attachment id and the
  // `TerminalViewerTransport.retired` hook, and nothing else.

  test("ACK_TIMEOUT reports recovery without enabling raw output", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo one\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");

    // Never acknowledged: the hub retires this attachment on its own clock,
    // with no inbound verb for agent-core to have observed.
    await waitFor(
      sent,
      (m) => m.type === "terminal:display:status" && m.code === "ACK_TIMEOUT",
      "ACK_TIMEOUT",
      TERMINAL_ACK_TIMEOUT_MS + 10_000,
    );

    sent.length = 0;
    await expectNoStreamAfterInput(bus, sent, "echo two\r");
  }, 60_000);

  test("a terminal:unsubscribe naming an attachment the connection does not hold changes nothing", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    const subscribed = await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");

    // The shape a stale unsubscribe takes after a re-subscribe: right runId,
    // an attachmentId this connection has already replaced. `unsubscribe`
    // refuses it, so the suppression must stand too — otherwise the SAME
    // viewer receives frames and raw output for one terminal at once.
    bus.dispatchInbound(
      createMessage("terminal:unsubscribe", {
        terminalId: "adhoc", runId: subscribed.runId, attachmentId: crypto.randomUUID(),
      }),
      "control",
      "loopback",
    );
    await new Promise((resolve) => setTimeout(resolve, 150));

    sent.length = 0;
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo mixed\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");
    expect(sent.some((m) => m.type === "terminal:output" && m.terminalId === "adhoc")).toBe(false);
  });

  test("a terminal that exits tells its frame viewer ENDED, with the exit code", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;
    bus.subscribe({ audience: "loopback", deliver: (message) => {
      if (message.type === "terminal:frame") {
        bus.dispatchInbound(createMessage("terminal:ack", {
          terminalId: message.terminalId, runId: message.runId,
          attachmentId: message.attachmentId, sequence: message.sequence,
        }), "control", "loopback");
      }
    } });

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo bye\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");

    sent.length = 0;
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "exit\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:exited" && m.terminalId === "adhoc", "terminal:exited", 20_000);
    const ended = await waitFor(
      sent,
      (m) => m.type === "terminal:display:status" && m.code === "ENDED" && m.terminalId === "adhoc",
      "ENDED status",
    );
    if (ended.type !== "terminal:display:status") throw new Error("unreachable");
    expect(ended.exitCode).not.toBeUndefined();
  }, 40_000);

  test("a same-id respawn ends the old subscription and requires a fresh attachment", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    const subscribed = await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo one\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");

    sent.length = 0;
    bus.dispatchInbound(createMessage("terminal:start", { terminalId: "adhoc", cwd: tmpdir() }), "control", "loopback");
    const ended = await waitFor(
      sent,
      (m) => m.type === "terminal:display:status" && m.code === "ENDED" && m.runId === subscribed.runId,
      "ENDED for the replaced run",
    );
    expect(ended.type).toBe("terminal:display:status");

    sent.length = 0;
    await expectNoStreamAfterInput(bus, sent, "echo two\r");
    expect(sent.some((m) => m.type === "terminal:frame")).toBe(false);
  }, 40_000);

  test("a relay viewer that backgrounds and returns keeps its subscription and resumes receiving frames", async () => {
    // The relay wire throughout: this viewer subscribed from the phone, so
    // both its reply and its frames are addressed there.
    const { bus, relaySent: sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "relay",
    );
    await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo one\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");

    // An ordinary background/foreground cycle, which is what `connState.suppressed`
    // reports for the whole time the app is away — and what `viewerTransportFor`
    // refuses delivery on.
    bus.dispatchInbound(createMessage("client:focus-state", { paused: true }), "control", "relay");
    await new Promise((resolve) => setTimeout(resolve, 200));
    bus.dispatchInbound(createMessage("client:focus-state", { paused: false }), "control", "relay");

    sent.length = 0;
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo two\r" }), "control", "loopback");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame after resume");
  }, 30_000);

  test("a subscribe still in flight when the connection drops leaves no mark behind for the reconnecting client", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId: crypto.randomUUID() }),
      "control",
      "loopback",
    );
    // Lands inside the checkout-resolution await the dispatcher runs before
    // the subscribe case is reached at all.
    core!.noteClientGone("loopback");
    await new Promise((resolve) => setTimeout(resolve, 300));

    sent.length = 0;
    await expectNoStreamAfterInput(bus, sent, "echo back\r");
  }, 30_000);

  test("mode exclusivity is GLOBAL per terminal: suppression holds even for output driven by a DIFFERENT source than the frame subscriber", async () => {
    const { bus, sent } = await bootWithTerminal();
    sent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "loopback",
    );
    const subscribed = await waitFor(sent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed");
    if (subscribed.type !== "terminal:subscribed") throw new Error("unreachable");

    sent.length = 0;
    // "relay" (a different InboundSource than the "loopback" subscriber above)
    // drives this input -- MessageBus.publish has no per-recipient delivery
    // (see frameSubscribedTerminals's own doc in agent-core.ts), so the
    // suppression this proves is global-per-terminal, not per-connection.
    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo hi\r" }), "control", "relay");
    await waitFor(sent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame");
    expect(sent.some((m) => m.type === "terminal:output" && m.terminalId === "adhoc")).toBe(false);

    bus.dispatchInbound(
      createMessage("terminal:unsubscribe", {
        terminalId: "adhoc", runId: subscribed.runId, attachmentId: subscribed.attachmentId,
      }),
      "control",
      "loopback",
    );
    await new Promise((resolve) => setTimeout(resolve, 100));
    sent.length = 0;
    await expectNoStreamAfterInput(bus, sent, "echo bye\r", "relay");
  });

  test("an unsubscribed desktop receives no raw output while a relay viewer receives frames", async () => {
    const { bus, sent, relaySent } = await bootWithTerminal();
    sent.length = 0;
    relaySent.length = 0;

    const requestId = crypto.randomUUID();
    bus.dispatchInbound(
      createMessage("terminal:subscribe", { terminalId: "adhoc", version: TERMINAL_PROTOCOL_VERSION, requestId }),
      "control",
      "relay",
    );
    await waitFor(relaySent, (m) => m.type === "terminal:subscribed" && m.requestId === requestId, "terminal:subscribed on the relay wire");

    bus.dispatchInbound(createMessage("terminal:input", { terminalId: "adhoc", data: "echo hi\r" }), "control", "loopback");

    await waitFor(relaySent, (m) => m.type === "terminal:frame" && m.terminalId === "adhoc", "terminal:frame on the relay wire");
    expect(sent.some((m) => m.type === "terminal:output")).toBe(false);
    expect(relaySent.some((m) => m.type === "terminal:output" && m.terminalId === "adhoc")).toBe(false);
    expect(sent.some((m) => m.type === "terminal:frame")).toBe(false);
  }, 30_000);
});
