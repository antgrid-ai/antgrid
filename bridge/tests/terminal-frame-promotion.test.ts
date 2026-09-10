// Wave 3 promoted the experimental frame VT into TerminalManager's per-PTY
// emulator slot. terminal-frame-source.test.ts and terminal-frame-queries.test.ts
// already cover the VT and the query responders in isolation; this file covers
// the WIRING — the behaviors that only exist once TerminalManager owns the
// construction, disposal, rebuild and query-install decisions (D1-D6 in the
// wave 3 spec). Every test drives TerminalManager's public surface; where a
// test needs to force a failure state that only a real parser overflow would
// otherwise reach, it overrides the `failure` getter on the real, live screen
// instance TerminalManager already constructed, rather than fabricating a
// stand-in class — `ensureLiveScreen`'s `instanceof TerminalFrameSource` check
// must still see a real one.
import { describe, test, expect, beforeEach, mock } from "bun:test";
import { TerminalManager } from "../src/terminal-manager";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import * as SourceModule from "../src/terminal-frames/source";
import { createConnState, type ConnState } from "../src/conn-state";
import type { AbMessage } from "../src/protocol";

const isWin = process.platform === "win32";

async function waitFor<T>(probe: () => T | undefined, timeoutMs: number): Promise<T | undefined> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = probe();
    if (value !== undefined) return value;
    if (Date.now() >= deadline) return undefined;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
}

function countOccurrences(haystack: string, needle: string): number {
  return haystack.split(needle).length - 1;
}

/**
 * A batched capability-query burst: one query of each kind this bridge
 * audits, in the order a real TUI's startup burst tends to send them.
 *
 * NOT delivered through a real spawned child's own stdout — measured (a bare
 * `bun-pty` spawn with ZERO bridge responders anywhere in the process) that
 * on Windows, ConPTY itself intercepts and answers DA1/CPR/DECRQM before the
 * bridge's `pty.onData` ever sees them: that zero-responder spawn still received
 * `\x1b[?61;6;7;21;22;23;24;28;32;42c\x1b[1;1R\x1b[?25;1$y` on the child's
 * stdin — ConPTY's own DA1 reply (not ours), plus CPR/DECRQM answered from
 * its own screen-buffer tracking (coincidentally matching our defaults,
 * since ConPTY has no PTY output to track otherwise). OSC 11 got no reply at
 * all from that bare spawn, which is the one query type genuinely
 * observable end-to-end here. So the two "exactly once" tests below drive
 * the real entry points TerminalManager wires up — `session`'s (private)
 * `respondToCapabilityQueries` and `screen.feed` — directly with these
 * bytes, exactly as `pty.onData`/the `terminal:output` handler would call
 * them in production, and inspect `session.write` (the single point both
 * paths funnel their replies through) instead of a live PTY round trip.
 */
const QUERY_BURST = "\x1b]11;?\x07\x1b[c\x1b[6n\x1b[?25$p";
const OSC11_REPLY = "\x1b]11;rgb:0909/0909/0b0b\x07";
const DA1_REPLY = "\x1b[?64;1;2;6;9;15;18;21;22c";
const CPR_REPLY = "\x1b[1;1R";
const DECRQM_REPLY = "\x1b[?25;1$y";

/** Wraps `session.write` to capture every reply it sends, in order, without
 *  needing a live PTY on the other end to read them. */
function captureWrites(session: unknown): string[] {
  const s = session as { write: (data: string) => void };
  const original = s.write.bind(s);
  const writes: string[] = [];
  s.write = (data: string) => {
    writes.push(data);
    original(data);
  };
  return writes;
}

// Verified empirically (not just documented) that Bun's `mock.module` cannot
// be undone within a `bun test` PROCESS, not just a file: a wholesale replace
// (as the first version of this helper did — a class whose constructor
// always throws) leaked into every OTHER test file that constructs a
// `TerminalFrameSource`, because `bun run --filter antgrid-bridge test`
// loads the whole suite into one process and Bun's module registry is
// process-global — neither a later `mock.module` back to the real module
// object nor `mock.restore()` releases the first replacement, so it was
// still live when `terminal-frame-source.test.ts` ran afterwards.
//
// The fix is a WRAPPER, not a replacement: this subclasses the real,
// eagerly-captured `TerminalFrameSource` and throws only for the span of one
// deliberately armed construction, then falls straight through to `super()`.
// Installed once, unconditionally, at module load — before ANY test in ANY
// file can construct one — so every other caller in the whole process (this
// file's other tests included) gets a functionally transparent stand-in, and
// `instanceof TerminalFrameSource` still holds for its instances everywhere,
// since the live binding every file reads now names this subclass.
const RealTerminalFrameSource = SourceModule.TerminalFrameSource;
let throwOnNextFrameSourceConstruct = false;
mock.module("../src/terminal-frames/source", () => ({
  ...SourceModule,
  TerminalFrameSource: class extends RealTerminalFrameSource {
    constructor(...args: ConstructorParameters<typeof RealTerminalFrameSource>) {
      if (throwOnNextFrameSourceConstruct) {
        throwOnNextFrameSourceConstruct = false;
        throw new Error("simulated unsupported xterm build");
      }
      super(...args);
    }
  },
}));

/** Arms exactly one throw, standing in for an unsupported xterm build (D2) —
 *  see the module-scope `mock.module` call above for why this is safe to
 *  call from more than one test in this file, in any order. */
function useThrowingFrameSourceCtor(): void {
  throwOnNextFrameSourceConstruct = true;
}

/** Forces `ensureLiveScreen` to treat `screen` as latched, without going
 *  through a real parser overflow. */
function forceFailure(screen: unknown, message = "simulated parser overflow"): void {
  Object.defineProperty(screen, "failure", {
    configurable: true,
    get: () => new Error(message),
  });
}

describe("terminal frame promotion (TerminalManager wiring)", () => {
  let manager: TerminalManager;
  let messages: AbMessage[];
  let connState: ConnState;

  beforeEach(() => {
    messages = [];
    connState = createConnState();
    manager = new TerminalManager((msg) => messages.push(msg), undefined, connState);
  });

  test("run id is new per respawn and stable across a retainScrollbackOnExit exit", async () => {
    manager.spawn({
      terminalId: "t1",
      retainScrollbackOnExit: true,
      command: isWin ? "cmd.exe" : "/bin/sh",
      args: isWin ? ["/c", "exit"] : ["-c", "exit 0"],
    });
    await new Promise((r) => setTimeout(r, 150));
    const runId1 = manager.runId("t1");
    expect(runId1).toBeDefined();

    expect(await waitFor(() => (manager.has("t1") ? undefined : true), 5000)).toBe(true);
    // Retained: the screen (and the run id living beside it) survives the exit.
    expect(manager.runId("t1")).toBe(runId1);

    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 150));
    const runId2 = manager.runId("t1");
    expect(runId2).toBeDefined();
    expect(runId2).not.toBe(runId1);

    manager.killAll();
  });

  test("a screen whose dispose throws does not abort resetMaps and the other screens are still disposed", async () => {
    manager.spawn({ terminalId: "t1" });
    manager.spawn({ terminalId: "t2" });
    await new Promise((r) => setTimeout(r, 200));

    const screens = (manager as unknown as { screens: Map<string, { dispose: () => void }> }).screens;
    const s1 = screens.get("t1");
    const s2 = screens.get("t2");
    expect(s1).toBeDefined();
    expect(s2).toBeDefined();

    s1!.dispose = () => {
      throw new Error("dispose boom");
    };
    let s2Disposed = false;
    const originalS2Dispose = s2!.dispose.bind(s2);
    s2!.dispose = () => {
      s2Disposed = true;
      originalS2Dispose();
    };

    manager.killAll();

    expect(s2Disposed).toBe(true);
    // disposeScreen deletes its map entries unconditionally, even when the
    // dispose call itself threw.
    expect(manager.runId("t1")).toBeUndefined();
    expect(manager.runId("t2")).toBeUndefined();
    expect(manager.has("t1")).toBe(false);
    expect(manager.has("t2")).toBe(false);
  });

  test("a latched frame source is rebuilt and reseeded from the scrollback, and getAttachSnapshot still returns a real snapshot", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 150));
    manager.write("t1", isWin ? "echo marker-hello\r" : "echo marker-hello\n");
    await new Promise((r) => setTimeout(r, 400));

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    const before = screens.get("t1");
    expect(before).toBeInstanceOf(TerminalFrameSource);
    const runIdBefore = manager.runId("t1");

    forceFailure(before);

    const snap = await manager.getAttachSnapshot("t1");
    expect(snap).not.toBeNull();
    expect(snap!.text).toContain("marker-hello");

    const after = screens.get("t1");
    expect(after).not.toBe(before);
    expect(after).toBeInstanceOf(TerminalFrameSource);
    // Same PTY run — a rebuild replaces the emulator, not the run it belongs to.
    expect(manager.runId("t1")).toBe(runIdBefore);

    manager.killAll();
  });

  test("a rebuild triggered by getAttachSnapshot does not orphan the output handler", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 150));
    manager.write("t1", isWin ? "echo marker-one\r" : "echo marker-one\n");
    await new Promise((r) => setTimeout(r, 400));

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    forceFailure(screens.get("t1"));

    // Rebuild via the ATTACH path, not the output handler — this is the path
    // that used to leave the output handler's own closure pointing at the
    // disposed generation forever.
    const snap1 = await manager.getAttachSnapshot("t1");
    expect(snap1!.text).toContain("marker-one");
    const rebuilt = screens.get("t1");
    expect(rebuilt).not.toBeUndefined();

    manager.write("t1", isWin ? "echo marker-two\r" : "echo marker-two\n");
    await new Promise((r) => setTimeout(r, 400));

    const snap2 = await manager.getAttachSnapshot("t1");
    expect(snap2!.text).toContain("marker-two");
    // No SECOND rebuild happened — the replacement `getAttachSnapshot` built
    // is the one that kept receiving live output, not a screen frozen at
    // "marker-one" that a healthy-looking source never gets to replace again.
    expect(screens.get("t1")).toBe(rebuilt);

    manager.killAll();
  });

  test("the output-path rebuild does not duplicate the chunk that triggered it", async () => {
    manager.spawn({ terminalId: "t1" });
    // Long enough that the shell's own post-init chatter (mintty's
    // win32-input-mode/focus-reporting enable on Windows, observed to
    // otherwise land AFTER this point and soak up the one rebuild this test
    // means to trigger) has already arrived — the write below must be what
    // lands on the failed screen, not an unrelated trailing chunk.
    await new Promise((r) => setTimeout(r, 800));

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    forceFailure(screens.get("t1"));

    // The NEXT chunk arrives through the real PTY -> `terminal:output`
    // handler, which is where the rebuild-triggering feed happens (as
    // opposed to the attach path exercised above).
    manager.write("t1", isWin ? "echo XYZZY1\r" : "echo XYZZY1\n");
    await new Promise((r) => setTimeout(r, 400));

    const snap = await manager.getAttachSnapshot("t1");
    // Once for the shell's own echo of the command, once for its output —
    // never twice each from a reseed that already ended with this chunk.
    expect(countOccurrences(snap!.text, "XYZZY1")).toBe(2);

    manager.killAll();
  });

  test("a rebuild's reseed does not answer capability queries sitting in the scrollback onto the live PTY", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 200));

    const session = (manager as unknown as { sessions: Map<string, unknown> }).sessions.get("t1");
    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    const scrollbacks = (manager as unknown as {
      scrollbacks: Map<string, { append: (d: string) => void }>;
    }).scrollbacks;

    // A plausible startup burst sitting in the tail the rebuild will reseed
    // from — DA1 and CPR, exactly what a TUI's handshake leaves behind.
    scrollbacks.get("t1")!.append("\x1b[c\x1b[6n");
    forceFailure(screens.get("t1"));

    const writes = captureWrites(session);
    await manager.getAttachSnapshot("t1");
    // The reseed's own settle-then-wire step is asynchronous; give any
    // erroneous reply a chance to actually land before asserting none did.
    await new Promise((r) => setTimeout(r, 100));

    expect(writes.join("")).toBe("");

    manager.killAll();
  });

  test("once the rebuild budget is exhausted, the session's own responder answers every query again", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 200));

    const session = (manager as unknown as { sessions: Map<string, unknown> }).sessions.get("t1");
    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;

    for (let i = 0; i < 4; i++) {
      forceFailure(screens.get("t1"));
      await manager.getAttachSnapshot("t1"); // rebuilds 1..3, then exhausted
    }

    const writes = captureWrites(session);
    (session as { respondToCapabilityQueries: (d: string) => void }).respondToCapabilityQueries(QUERY_BURST);
    const combined = writes.join("");
    // The latched source's own parser boundary answers nothing (`feed` is a
    // no-op once failed) — the session's byte responder is the only thing
    // left, and it must have been widened back to full scope rather than
    // stuck narrowed to OSC-colors from the frame source that is now gone.
    expect(countOccurrences(combined, OSC11_REPLY)).toBe(1);
    expect(countOccurrences(combined, DA1_REPLY)).toBe(1);
    expect(countOccurrences(combined, CPR_REPLY)).toBe(1);
    expect(countOccurrences(combined, DECRQM_REPLY)).toBe(1);

    manager.killAll();
  });

  test("an OSC reply does not overtake a same-chunk parser reply that preceded it", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 200));

    const session = (manager as unknown as { sessions: Map<string, unknown> }).sessions.get("t1");
    const screen = (manager as unknown as {
      screens: Map<string, { feed: (d: string) => void; settle: () => Promise<void> }>;
    }).screens.get("t1");
    expect(screen).toBeInstanceOf(TerminalFrameSource);

    const writes = captureWrites(session);
    const burst = "\x1b[c\x1b]11;?\x07"; // DA1 first, OSC 11 second — guest order
    (session as { respondToCapabilityQueries: (d: string) => void }).respondToCapabilityQueries(burst);
    screen!.feed(burst);
    await screen!.settle();

    // Before this fix the OSC reply, written synchronously off the raw PTY
    // chunk, always beat the parser-boundary DA1 reply — regardless of which
    // one the guest actually asked first.
    expect(writes).toEqual([DA1_REPLY, OSC11_REPLY]);

    manager.killAll();
  });

  test("the rebuild budget stops at 3", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 150));

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    const runIdBefore = manager.runId("t1");

    forceFailure(screens.get("t1"));
    await manager.getAttachSnapshot("t1"); // rebuild 1/3
    const afterRebuild1 = screens.get("t1");
    expect(afterRebuild1).not.toBeUndefined();

    forceFailure(screens.get("t1"));
    await manager.getAttachSnapshot("t1"); // rebuild 2/3
    const afterRebuild2 = screens.get("t1");
    expect(afterRebuild2).not.toBe(afterRebuild1);

    forceFailure(screens.get("t1"));
    await manager.getAttachSnapshot("t1"); // rebuild 3/3 — budget now spent
    const afterRebuild3 = screens.get("t1");
    expect(afterRebuild3).not.toBe(afterRebuild2);

    forceFailure(screens.get("t1"));
    const snap = await manager.getAttachSnapshot("t1"); // 4th: budget exhausted
    expect(snap).not.toBeNull(); // never null just because a source is latched
    expect(screens.get("t1")).toBe(afterRebuild3); // no further rebuild

    expect(manager.runId("t1")).toBe(runIdBefore);

    manager.killAll();
  });

  test("OSC 11 is answered exactly once by the byte responder; DA1, CPR and DECRQM exactly once at the parser boundary", async () => {
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 200));

    const session = (manager as unknown as { sessions: Map<string, unknown> }).sessions.get("t1");
    const screen = (manager as unknown as {
      screens: Map<string, { feed: (d: string) => void; settle: () => Promise<void> }>;
    }).screens.get("t1");
    expect(session).toBeDefined();
    expect(screen).toBeInstanceOf(TerminalFrameSource);

    const writes = captureWrites(session);
    // Same bytes through both real entry points, exactly as a live PTY chunk
    // would reach them in production: the byte responder first (pty.onData),
    // then the parser boundary (the terminal:output handler feeding screen).
    // xterm's write buffer is async (see TerminalScreen.feed's doc comment),
    // so the parser-boundary handlers that answer DA1/CPR/DECRQM have not
    // necessarily run by the time `feed` returns — `settle()` is the barrier.
    (session as { respondToCapabilityQueries: (d: string) => void }).respondToCapabilityQueries(QUERY_BURST);
    screen!.feed(QUERY_BURST);
    await screen!.settle();

    const combined = writes.join("");
    // OSC 10/11/12 stay with the byte-level responder even once a frame
    // source is installed — the parser boundary never registers a handler
    // for them (see queries.ts's header) — so this is unaffected by narrowing.
    expect(countOccurrences(combined, OSC11_REPLY)).toBe(1);
    // DA1/CPR/DECRQM would each appear TWICE if the session's own byte
    // responder were still answering them alongside the frame source's
    // parser-boundary responder — narrowCapabilityResponder is what keeps
    // this at exactly one (the byte responder, narrowed to osc-colors,
    // ignores them; only the parser boundary answers).
    expect(countOccurrences(combined, DA1_REPLY)).toBe(1);
    expect(countOccurrences(combined, CPR_REPLY)).toBe(1);
    expect(countOccurrences(combined, DECRQM_REPLY)).toBe(1);

    manager.killAll();
  });

  test("a resize immediately followed by settle serializes at the new geometry", async () => {
    manager.spawn({ terminalId: "t1", cols: 80, rows: 24 });
    await new Promise((r) => setTimeout(r, 200));

    const screens = (manager as unknown as { screens: Map<string, { term: { cols: number; rows: number } }> })
      .screens;
    expect(screens.get("t1")!.term.cols).toBe(80);

    manager.resize("t1", "test-client", 100, 30);
    // TerminalFrameSource.resize defers into a parser write callback, so the
    // geometry TerminalManager just asked for is not applied synchronously.
    expect(screens.get("t1")!.term.cols).toBe(80);

    const snap = await manager.getAttachSnapshot("t1");
    expect(snap).not.toBeNull();
    expect(screens.get("t1")!.term.cols).toBe(100);
    expect(screens.get("t1")!.term.rows).toBe(30);

    manager.killAll();
  });

  test("a constructor throw falls back to TerminalScreen and the terminal still spawns", async () => {
    useThrowingFrameSourceCtor();
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 150));

    expect(manager.has("t1")).toBe(true);
    expect(messages.some((m) => m.type === "terminal:started" && m.terminalId === "t1")).toBe(true);
    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    expect(screens.get("t1")).not.toBeInstanceOf(TerminalFrameSource);

    manager.killAll();
  });

  test("the fallback path still answers every query", async () => {
    useThrowingFrameSourceCtor();
    manager.spawn({ terminalId: "t1" });
    await new Promise((r) => setTimeout(r, 200));

    const session = (manager as unknown as { sessions: Map<string, unknown> }).sessions.get("t1");
    const screen = (manager as unknown as {
      screens: Map<string, { feed: (d: string) => void; settle: () => Promise<void> }>;
    }).screens.get("t1");
    expect(session).toBeDefined();
    expect(screen).not.toBeInstanceOf(TerminalFrameSource);

    const writes = captureWrites(session);
    (session as { respondToCapabilityQueries: (d: string) => void }).respondToCapabilityQueries(QUERY_BURST);
    // A plain TerminalScreen has no parser-boundary responder at all
    // (wireFrameQueries no-ops for it), so feeding it the same burst must
    // add nothing — every answer already came from the byte responder above.
    screen!.feed(QUERY_BURST);
    await screen!.settle();

    const combined = writes.join("");
    // The single full-scope byte responder is the ONLY responder on the
    // fallback path, so every query still gets exactly the answer it would
    // from a full TerminalFrameSource — including OSC 11, which a narrowed
    // responder would also have answered, and DA1/CPR/DECRQM, which a
    // narrowed one would not.
    expect(countOccurrences(combined, OSC11_REPLY)).toBe(1);
    expect(countOccurrences(combined, DA1_REPLY)).toBe(1);
    expect(countOccurrences(combined, CPR_REPLY)).toBe(1);
    expect(countOccurrences(combined, DECRQM_REPLY)).toBe(1);

    manager.killAll();
  });
});
