// The final screen of a run that ends: what a viewer is left looking at once
// the PTY is gone.
//
// Every case here is about one shape — a program whose last write and whose
// exit land on the same tick (`echo; exit`, a build printing its verdict, an
// agent finishing). xterm parses in slices, so those bytes are still queued
// when the exit arrives, and everything downstream of the exit is capable of
// running before the parser ever reaches them.
import { afterEach, describe, expect, test } from "bun:test";
import { TerminalManager, type TerminalManagerCallbacks } from "../src/terminal-manager";
import { createConnState } from "../src/conn-state";
import { setLogLevel } from "../src/logger";
import type { AbMessage, TerminalDisplayStatus, TerminalFrame } from "../src/protocol";
import {
  TerminalFrameHub, type TerminalAddress, type TerminalViewerTransport,
} from "../src/terminal-frames/delivery";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { TERMINAL_FRAME_INTERVAL_MS, TERMINAL_PROTOCOL_VERSION } from "../src/terminal-frames/protocol";

setLogLevel("error");

const addr = (terminalId = "t1"): TerminalAddress => ({ projectId: "p", checkoutId: "main", terminalId });

const sources: TerminalFrameSource[] = [];
function source(cols = 40, rows = 6): TerminalFrameSource {
  const screen = new TerminalFrameSource(cols, rows);
  sources.push(screen);
  return screen;
}
afterEach(() => {
  for (const screen of sources.splice(0)) screen.dispose();
});

class FakeTransport implements TerminalViewerTransport {
  sent: (TerminalFrame | TerminalDisplayStatus | AbMessage)[] = [];
  authorized(): boolean { return true; }
  send(message: TerminalFrame | TerminalDisplayStatus | AbMessage): Promise<void> {
    this.sent.push(message);
    return Promise.resolve();
  }
}
const frames = (t: FakeTransport) => t.sent.filter((m): m is TerminalFrame => m.type === "terminal:frame");
const statuses = (t: FakeTransport) =>
  t.sent.filter((m): m is TerminalDisplayStatus => m.type === "terminal:display:status");

describe("a finished run's last frame", () => {
  test("keeps the immutable final frame after emulator release until the viewer consumes it", async () => {
    let now = 1000;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    const runId = crypto.randomUUID();
    hub.register(addr(), screen, runId);
    const transport = new FakeTransport();
    const connection = hub.connect(transport);
    const attachmentId = (await connection.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID()))!;
    screen.feed("FINAL-RETAINED");
    now += TERMINAL_FRAME_INTERVAL_MS;
    await hub.finish(addr(), runId, 0);
    hub.releaseFinished(addr(), runId, 0);
    screen.dispose();
    now += 1000;
    hub.tick();
    expect(hub.find(addr())).toBeDefined();
    expect(statuses(transport).some((status) => status.code === "ENDED")).toBe(false);
    const last = frames(transport).at(-1)!;
    expect(last.ansi).toContain("FINAL-RETAINED");
    connection.acknowledge(addr(), { runId, attachmentId, sequence: last.sequence });
    hub.tick();
    expect(statuses(transport).some((status) => status.code === "ENDED")).toBe(true);
    expect(hub.find(addr())).toBeUndefined();
    hub.dispose();
  });
  test("carries a line written inside the capture interval of the frame before it", async () => {
    let now = 1000;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    const runId = crypto.randomUUID();
    hub.register(addr(), screen, runId);
    const transport = new FakeTransport();
    const connection = hub.connect(transport);
    const attachmentId = await connection.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attachmentId).toBeDefined();

    screen.feed("BOOT\r\n");
    await screen.settle();
    now += TERMINAL_FRAME_INTERVAL_MS + 10;
    hub.tick();
    const booted = frames(transport).at(-1)!;
    expect(booted.ansi).toContain("BOOT");
    connection.acknowledge(addr(), { runId, attachmentId: attachmentId!, sequence: booted.sequence });

    screen.feed("THE-LAST-LINE\r\n");
    const finishing = hub.finish(addr(), runId, 0);
    await screen.settle();
    expect(frames(transport).at(-1)!.ansi).not.toContain("THE-LAST-LINE");
    now += TERMINAL_FRAME_INTERVAL_MS;
    await finishing;
    hub.tick();

    const last = frames(transport).at(-1)!;
    expect(last.ansi).toContain("THE-LAST-LINE");
    // The run is over, but the viewer has not confirmed the screen yet.
    expect(statuses(transport).some((m) => m.code === "ENDED")).toBe(false);
    connection.acknowledge(addr(), { runId, attachmentId: attachmentId!, sequence: last.sequence });
    hub.tick();
    expect(statuses(transport).find((m) => m.code === "ENDED")?.exitCode).toBe(0);
  });

  test("is captured even though the guest exited inside an unclosed frame block", async () => {
    let now = 1000;
    const hub = new TerminalFrameHub(() => now);
    const screen = source();
    const runId = crypto.randomUUID();
    hub.register(addr(), screen, runId);
    const transport = new FakeTransport();
    const connection = hub.connect(transport);
    await connection.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());

    // DECSET 2026 opened and never closed: the program died mid-repaint, so no
    // end-of-block is ever coming.
    screen.feed("\x1b[?2026hDYING-BREATH\r\n");
    now += TERMINAL_FRAME_INTERVAL_MS;
    await hub.finish(addr(), runId, 1);

    const last = frames(transport).at(-1);
    expect(last?.ansi).toContain("DYING-BREATH");
    // Reported as what it is, rather than passed off as a settled screen.
    expect(last?.syncTimedOut).toBe(true);
  });

  test("a late finish for a replaced run cannot capture over its successor", async () => {
    const hub = new TerminalFrameHub(() => 0);
    const first = crypto.randomUUID();
    hub.register(addr(), source(), first);
    const second = crypto.randomUUID();
    hub.register(addr(), source(), second);

    await hub.finish(addr(), first, 0);
    expect(hub.find(addr())?.runId).toBe(second);
    expect(hub.find(addr())?.finalRevision).toBeUndefined();
  });

  test("a finished run whose emulator is rebuilt still ends its viewer, on the rebuilt screen", async () => {
    // `TerminalManager.ensureLiveScreen` re-registers a replacement emulator
    // under the run the PTY was already known by — including for a run that
    // has already exited, where a retained terminal keeps its screen with
    // nothing else left to remove it.
    let now = 1000;
    const hub = new TerminalFrameHub(() => now);
    const dying = source();
    const runId = crypto.randomUUID();
    hub.register(addr(), dying, runId);
    const transport = new FakeTransport();
    const connection = hub.connect(transport);
    const attachmentId = await connection.subscribe(addr(), TERMINAL_PROTOCOL_VERSION, crypto.randomUUID());
    expect(attachmentId).toBeDefined();

    // Ten parsed writes put the dead emulator's revision past anything a
    // replacement, whose own counter starts at 0, could reach by replaying one
    // screen's worth of scrollback.
    for (let index = 0; index < 10; index++) { dying.feed(`LINE-${index}\r\n`); await dying.settle(); }
    await hub.finish(addr(), runId, 4);
    expect(hub.find(addr())?.finalRevision).toBeGreaterThan(1);
    // Nothing acknowledged yet, so the viewer is still attached when the
    // rebuild lands.
    expect(statuses(transport).some((m) => m.code === "ENDED")).toBe(false);

    const rebuilt = source();
    hub.register(addr(), rebuilt, runId);
    rebuilt.feed("REBUILT-SCREEN\r\n"); // the reseed ensureLiveScreen performs next
    await rebuilt.settle();
    await new Promise((r) => setTimeout(r, 0));

    for (let round = 0; round < 10; round++) {
      const last = frames(transport).at(-1);
      if (last) connection.acknowledge(addr(), { runId, attachmentId: attachmentId!, sequence: last.sequence });
      now += TERMINAL_FRAME_INTERVAL_MS + 10;
      hub.tick();
      await new Promise((r) => setTimeout(r, 0));
    }

    expect(statuses(transport).find((m) => m.code === "ENDED")?.exitCode).toBe(4);
    // The screen it ends on is the replacement's, not the blank grid the
    // replacement held at the moment it was registered. Carried by the
    // ordinary tick/frame path in the loop above rather than by `finish`'s own
    // unthrottled final capture — that one ran against the dead emulator,
    // before this replacement existed. The final capture is pinned by the two
    // tests at the top of this file instead.
    expect(frames(transport).at(-1)!.ansi).toContain("REBUILT-SCREEN");
  });
});

describe("TerminalManager's exit teardown", () => {
  // Every wait below is on a spawned process reaching a state — a spawn, an
  // exit, the 250 ms drain timer that follows it. This suite runs 289 files in
  // parallel, where each of those takes an unbounded multiple of whatever a
  // fixed sleep guesses. Returns on timeout rather than throwing, so the
  // assertion underneath reports which state was never reached.
  async function waitUntil(condition: () => boolean, timeoutMs = 15_000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (!condition() && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  }

  const managers: TerminalManager[] = [];
  function build(callbacks: TerminalManagerCallbacks): TerminalManager {
    const made = new TerminalManager(() => {}, callbacks, createConnState());
    managers.push(made);
    return made;
  }
  afterEach(() => {
    for (const made of managers.splice(0)) made.killAll();
  });

  test("hands a frame consumer the drained final screen before evicting the run", async () => {
    const order: string[] = [];
    let started: TerminalFrameSource | undefined;
    let aliveAtExit: boolean | undefined;
    let drained = "";
    const made = build({
      onRunStarted: (_id, _runId, screen) => { started = screen; },
      onRunExited: () => {
        order.push("exited");
        aliveAtExit = started !== undefined && !started.isDisposed;
        // Exactly what the frame hub does with this callback: settle the parse,
        // then read the screen the program actually died holding.
        void started?.settle().then(() => { drained = started!.visibleLines().join("\n"); });
      },
      onRunEnded: () => { order.push("ended"); },
    });

    // Prints and exits on the same tick, leaving the parser no pause to use.
    made.spawn({
      terminalId: "t1",
      command: process.execPath,
      args: ["-e", "process.stdout.write('THE-LAST-LINE\\r\\n'); process.exit(0)"],
    });
    await waitUntil(() => order.length === 2 && drained !== "");

    expect(order).toEqual(["exited", "ended"]);
    expect(aliveAtExit).toBe(true);
    expect(drained).toContain("THE-LAST-LINE");
  }, 20000);

  test("waits for capture completion even beyond the minimum drain window", async () => {
    let complete!: () => void;
    const capture = new Promise<void>((resolve) => { complete = resolve; });
    let screen: TerminalFrameSource | undefined;
    let exited = false;
    const made = build({
      onRunStarted: (_id, _runId, value) => { screen = value; },
      onRunExited: () => { exited = true; return capture; },
    });
    made.spawn({ terminalId: "slow", command: process.execPath, args: ["-e", "process.exit(0)"] });
    await waitUntil(() => exited);
    await new Promise((resolve) => setTimeout(resolve, 400));
    expect(screen!.isDisposed).toBe(false);
    complete();
    await waitUntil(() => screen!.isDisposed);
    expect(screen!.isDisposed).toBe(true);
  }, 20000);

  test("a same-id respawn inside the drain window keeps its own screen and still reports the dead run's exit code", async () => {
    const started: string[] = [];
    const ended: { runId: string; exitCode?: number | null }[] = [];
    const screens: TerminalFrameSource[] = [];
    let made!: TerminalManager;
    let respawned = false;
    let signalRespawn!: () => void;
    const respawn = new Promise<void>((resolve) => { signalRespawn = resolve; });
    made = build({
      onRunStarted: (_id, runId, screen) => { started.push(runId); screens.push(screen); },
      onRunEnded: (_id, runId, exitCode) => { ended.push({ runId, exitCode }); },
      // On the exit itself, which is the only way to land inside a 250 ms
      // window from a test: sleeping first closes it and leaves the timer's
      // identity guard uncovered.
      onTerminalExited: () => {
        if (respawned) return;
        respawned = true;
        made.spawn({ terminalId: "t1", command: process.execPath, args: ["-e", "setTimeout(() => {}, 60000)"] });
        signalRespawn();
      },
    });
    made.spawn({ terminalId: "t1", command: process.execPath, args: ["-e", "process.exit(7)"] });
    await respawn;
    expect(screens.length).toBe(2);
    await waitUntil(() => ended.length > 0);
    // A second retirement could only come from the dead run's own drain timer,
    // which is already spent by the time the first one lands — so this is a
    // bounded window, not a race with a slow machine.
    await new Promise((r) => setTimeout(r, 400));

    // The dead run retires exactly once, carrying the code it actually exited
    // with; the live run's screen is untouched by the dead run's timer.
    expect(ended).toEqual([{ runId: started[0]!, exitCode: 7 }]);
    expect(screens[1]!.isDisposed).toBe(false);
  }, 20000);

  test("a screen failing inside the drain window is retired without reconstruction", async () => {
    const started: string[] = [];
    const ended: { runId: string; exitCode?: number | null }[] = [];
    const screens: TerminalFrameSource[] = [];
    let made!: TerminalManager;
    let signalExit!: () => void;
    const exited = new Promise<void>((resolve) => { signalExit = resolve; });
    made = build({
      onRunStarted: (_id, runId, screen) => { started.push(runId); screens.push(screen); },
      onRunEnded: (_id, runId, exitCode) => { ended.push({ runId, exitCode }); },
      onRunExited: () => {
        // The chunk the program printed on its way out overflows the parser
        // backlog, and an app attaches before the window closes: the attach
        // rebuilds the latched source, replacing the map entry under the SAME
        // run. Nothing but this window's timer will ever dispose it.
        screens[0]!.feed("x".repeat(1_100_000));
      },
      onTerminalExited: () => signalExit(),
    });
    made.spawn({ terminalId: "t1", command: process.execPath, args: ["-e", "process.exit(3)"] });
    await exited;
    expect(screens.length).toBe(1);
    expect(started).toEqual([started[0]!]);
    await waitUntil(() => ended.length > 0 && screens[0]!.isDisposed);

    expect(ended).toEqual([{ runId: started[0]!, exitCode: 3 }]);
    expect(screens[0]!.isDisposed).toBe(true);
  }, 20000);

  test("a respawn from inside the run-exited callback still reports the dead run's exit code", async () => {
    const started: string[] = [];
    const ended: { runId: string; exitCode?: number | null }[] = [];
    let made!: TerminalManager;
    let respawned = false;
    let signalRespawn!: () => void;
    const respawn = new Promise<void>((resolve) => { signalRespawn = resolve; });
    made = build({
      onRunStarted: (_id, runId) => { started.push(runId); },
      onRunEnded: (_id, runId, exitCode) => { ended.push({ runId, exitCode }); },
      // The one caller that can take the slot from INSIDE `dropAfterFinalFrame`
      // rather than after it has returned: the respawn's own `disposeScreen`
      // runs before this callback does, so the exit code it adopts has to be
      // recorded ahead of the call rather than after it.
      onRunExited: () => {
        if (respawned) return;
        respawned = true;
        made.spawn({ terminalId: "t1", command: process.execPath, args: ["-e", "setTimeout(() => {}, 60000)"] });
        signalRespawn();
      },
    });
    made.spawn({ terminalId: "t1", command: process.execPath, args: ["-e", "process.exit(5)"] });
    await respawn;

    expect(started.length).toBe(2);
    expect(ended).toEqual([{ runId: started[0]!, exitCode: 5 }]);
  }, 20000);
});
