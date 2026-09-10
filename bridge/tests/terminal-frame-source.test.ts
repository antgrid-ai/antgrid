import { afterEach, describe, expect, test } from "bun:test";
import type { Terminal } from "@xterm/headless";
import { TerminalFrameSource, SYNC_OUTPUT_TIMEOUT_MS } from "../src/terminal-frames/source";
import { TERMINAL_FRAME_MAX_ANSI_BYTES, encodedJsonBytes } from "../src/terminal-frames/protocol";
import type { TerminalRunHistory } from "../src/terminal-frames/history";

/** The backlog ceiling `feed()` refuses at. Private to source.ts on purpose —
 *  nothing outside it may tune the latch — so it is pinned as a literal here and
 *  a change on either side has to be a deliberate edit of both. */
const MAX_PENDING_CHARS = 1_000_000;

const sources: TerminalFrameSource[] = [];
function source(cols = 40, rows = 6): TerminalFrameSource {
  const screen = new TerminalFrameSource(cols, rows);
  sources.push(screen);
  return screen;
}
function term(screen: TerminalFrameSource): Terminal {
  return (screen as unknown as { term: Terminal }).term;
}
function uriAt(screen: TerminalFrameSource, row: number, col: number): string | undefined {
  const terminal = term(screen);
  const buffer = terminal.buffer.active;
  const cell = buffer.getLine(buffer.baseY + row)?.getCell(col) as unknown as { extended?: { urlId?: number } } | undefined;
  const id = cell?.extended?.urlId;
  if (!id) return undefined;
  const links = (terminal as unknown as {
    _core: { _oscLinkService: { getLinkData(id: number): { uri: string } | undefined } };
  })._core._oscLinkService;
  return links.getLinkData(id)?.uri;
}
/** Every cell distinctly coloured, so the serialized screen is dense with the
 *  one byte raw and JSON-encoded sizes disagree about. Fed a row at a time and
 *  settled, so the screen that reaches `capture()` is large without the INPUT
 *  ever reaching the backlog ceiling — the two limits must not be confused. */
async function paintDense(screen: TerminalFrameSource, cols: number, rows: number): Promise<void> {
  for (let row = 0; row < rows; row++) {
    let line = `\x1b[${row + 1};1H`;
    for (let col = 0; col < cols; col++) line += `\x1b[38;2;${10 + ((row + col) % 2)};20;30m#`;
    screen.feed(line);
    await screen.settle();
  }
}
/** A history that raises from the named call, as the real store does once its
 *  disk does: TerminalRunHistory.attempt() invokes the caller-supplied
 *  onFailure from inside its own catch, so the raise reaches the source. */
function failingHistory(fails: { append?: boolean; flush?: boolean }): TerminalRunHistory {
  return {
    append(): void { if (fails.append) throw new Error("history append: disk gone"); },
    flush(): void { if (fails.flush) throw new Error("history flush: disk gone"); },
    clear(): void {},
    boundary: () => ({ epoch: 0, firstRowId: 0, nextRowId: 0, status: "recording" as const }),
  } as unknown as TerminalRunHistory;
}
/** Whether the parser drained at all. A callback that threw out of xterm's write
 *  loop never retires its chunk, so this is how a frozen parser shows up. */
function settles(screen: TerminalFrameSource): Promise<boolean> {
  return Promise.race([
    screen.settle().then(() => true),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 250)),
  ]);
}

afterEach(() => { for (const screen of sources.splice(0)) screen.dispose(); });

describe("terminal frame source", () => {
  test("feed never throws, and the backlog it refuses is raised at capture", () => {
    const host = source();
    expect(() => host.feed("x".repeat(MAX_PENDING_CHARS + 1))).not.toThrow();
    // Latched: every later chunk is dropped in silence rather than retried, and
    // every later capture reports the same failure to whoever owns the viewer.
    expect(() => host.feed("more")).not.toThrow();
    expect(() => host.feed("x".repeat(MAX_PENDING_CHARS + 1))).not.toThrow();
    expect(() => host.capture(0)).toThrow("backlog");
    expect(() => host.capture(50)).toThrow("backlog");
    expect(host.hasPendingTail).toBe(false);
    expect(host.pendingTail()).toBe("");
  });

  test("feed and capture stay quiet on a disposed source", () => {
    const host = source();
    host.feed("before");
    host.dispose();
    expect(() => host.feed("after")).not.toThrow();
    expect(() => host.feed("x".repeat(MAX_PENDING_CHARS + 1))).not.toThrow();
    expect(host.capture(0)).toBeNull();
  });

  test("a latched source raises at capture even after disposal", () => {
    const host = source();
    host.feed("x".repeat(MAX_PENDING_CHARS + 1));
    host.dispose();
    expect(() => host.capture(0)).toThrow("backlog");
  });

  test("ordinary large traffic never latches", async () => {
    const host = source();
    // Each chunk is legal on its own and their SUM is far past the ceiling, so
    // this only passes while the pending counter is credited back on parse.
    for (let round = 0; round < 4; round++) {
      host.feed("\x1b[H" + "y".repeat(MAX_PENDING_CHARS - 3));
      await host.settle();
    }
    expect(host.revision).toBe(4);
    expect(() => host.capture(0)).not.toThrow();
    expect(host.capture(0)).not.toBeNull();
  }, 30_000);

  test("the display budget is spent in JSON-encoded bytes, and oversize skips one frame", async () => {
    // Dense truecolor: the serialized screen is comfortably under the cap as raw
    // UTF-8 and over it once JSON renders every ESC as six bytes. Before the
    // units were reconciled this frame was produced here and refused by the
    // sender, which killed the viewer instead of dropping the frame.
    const host = source(300, 180);
    await paintDense(host, 300, 180);
    const body = host.serializeNow();
    expect(Buffer.byteLength(body) + 1024).toBeLessThan(TERMINAL_FRAME_MAX_ANSI_BYTES);
    expect(encodedJsonBytes(body)).toBeGreaterThan(TERMINAL_FRAME_MAX_ANSI_BYTES);
    expect(host.capture(0)).toBeNull();
    expect(host.oversize).toBe(true);

    host.feed("\x1bc\x1b[Hback to something small");
    await host.settle();
    const frame = host.capture(50);
    expect(frame).not.toBeNull();
    expect(host.oversize).toBe(false);
    expect(encodedJsonBytes(frame!.ansi)).toBeLessThanOrEqual(TERMINAL_FRAME_MAX_ANSI_BYTES);
    expect(frame!.ansi).toContain("back to something small");
  }, 30_000);

  test("pendingTail carries the unparsed chunks and agrees with hasPendingTail", async () => {
    const host = source();
    expect(host.hasPendingTail).toBe(false);
    expect(host.pendingTail()).toBe("");

    host.feed("alpha");
    host.feed("\x1b[32m");
    host.feed("omega");
    expect(host.hasPendingTail).toBe(true);
    expect(host.pendingTail()).toBe("alpha\x1b[32momega");

    await host.settle();
    expect(host.hasPendingTail).toBe(false);
    expect(host.pendingTail()).toBe("");
  });

  test("capture waits for a synchronized redraw and gives up after the timeout", async () => {
    const host = source();
    host.feed("\x1b[?2026hpartial");
    expect(host.capture(0)).toBeNull();
    await host.settle();
    expect(host.capture(0)).toBeNull();
    expect(host.capture(SYNC_OUTPUT_TIMEOUT_MS - 1)).toBeNull();

    const timedOut = host.capture(SYNC_OUTPUT_TIMEOUT_MS);
    expect(timedOut?.syncTimedOut).toBe(true);
    expect(timedOut?.ansi).toContain("partial");

    host.feed(" done\x1b[?2026l");
    await host.settle();
    expect(host.capture(SYNC_OUTPUT_TIMEOUT_MS + 1)?.syncTimedOut).toBe(false);
  });

  test("OSC 8 targets survive a capture replayed into a fresh source", async () => {
    const host = source();
    host.feed(
      "\x1b[1;2H\x1b]8;;https://example.com/one\x1b\\alpha\x1b]8;;\x1b\\gap" +
      "\x1b[3;1H\x1b[1;38;2;20;100;200m\x1b]8;;https://example.com/two\x1b\\beta\x1b]8;;\x1b\\",
    );
    await host.settle();
    const frame = host.capture(0)!;

    const viewer = source();
    viewer.feed("stale content that must not survive\x1b]8;;https://stale.example\x1b\\x\x1b]8;;\x1b\\");
    viewer.feed(frame.ansi);
    await viewer.settle();

    expect(viewer.visibleLines()).toEqual(host.visibleLines());
    expect(uriAt(viewer, 0, 1)).toBe("https://example.com/one");
    expect(uriAt(viewer, 0, 5)).toBe("https://example.com/one");
    expect(uriAt(viewer, 0, 6)).toBeUndefined();
    expect(uriAt(viewer, 2, 0)).toBe("https://example.com/two");
    expect(uriAt(viewer, 2, 3)).toBe("https://example.com/two");
    expect(uriAt(viewer, 2, 4)).toBeUndefined();
    // The overlay repaints linked cells, so their styling has to survive it too.
    const beta = term(viewer).buffer.active.getLine(2)!.getCell(0)!;
    expect(beta.isBold()).toBeTruthy();
    expect(beta.getFgColor()).toBe(0x1464c8);
  });

  test("the Kitty keyboard stack tracks push, pop, set, or and and-not per buffer", async () => {
    const host = source();
    const flags = async (): Promise<string> => {
      await host.settle();
      return host.capture(0)!.ansi.match(/\x1b\[=(\d+);1u/)![1];
    };
    host.feed("\x1b[>1u");
    expect(await flags()).toBe("1");
    host.feed("\x1b[=6;2u");
    expect(await flags()).toBe("7");
    host.feed("\x1b[=4;3u");
    expect(await flags()).toBe("3");
    host.feed("\x1b[=9;1u");
    expect(await flags()).toBe("9");
    // Flags are five bits wide; anything above them is not the guest's to set.
    host.feed("\x1b[=63;1u");
    expect(await flags()).toBe("31");

    host.feed("\x1b[?1049h");
    expect(await flags()).toBe("0");
    host.feed("\x1b[>8u");
    expect(await flags()).toBe("8");
    host.feed("\x1b[?1049l");
    expect(await flags()).toBe("31");

    host.feed("\x1b[<u");
    expect(await flags()).toBe("0");
    host.feed("\x1b[<9u");
    expect(await flags()).toBe("0");

    host.feed("\x1b[>5u\x1b[?1049h\x1b[>7u\x1b[?1049l");
    expect(await flags()).toBe("5");
    host.feed("\x1bc");
    expect(await flags()).toBe("0");
    host.feed("\x1b[?1049h");
    expect(await flags()).toBe("0");
  });

  test("revision advances once per parsed write", async () => {
    const host = source();
    const parsed: number[] = [];
    const detach = host.onParsed(() => parsed.push(host.revision));
    expect(host.revision).toBe(0);

    host.feed("one");
    await host.settle();
    expect(host.revision).toBe(1);

    host.feed("two");
    host.feed("three");
    await host.settle();
    expect(host.revision).toBe(3);
    expect(parsed).toEqual([1, 2, 3]);

    detach();
    host.feed("four");
    await host.settle();
    expect(host.revision).toBe(4);
    expect(parsed).toEqual([1, 2, 3]);
  });

  test("a viewer that throws is isolated, and the parser survives it", async () => {
    // xterm retires a chunk only AFTER its write callback returns, so a throw
    // that escapes one stops the write buffer draining for the rest of the
    // process: every later feed parses nothing and every capture is null.
    const host = source();
    const ran: string[] = [];
    host.onParsed(() => { ran.push("first"); throw new Error("hostile viewer"); });
    host.onParsed(() => { ran.push("second"); });

    host.feed("hello");
    await host.settle();
    expect(ran).toEqual(["first", "second"]);

    host.feed("\r\nmore");
    const settled = await Promise.race([
      host.settle().then(() => true),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 250)),
    ]);
    expect(settled).toBe(true);
    expect(host.revision).toBe(2);
    expect(host.hasPendingTail).toBe(false);
    expect(host.capture(0)).not.toBeNull();
  });
  test("a resize that cannot reach its history degrades instead of escaping the parse loop", async () => {
    // reconcileResize is the one archive path that does NOT run under the
    // adapter's own guard — it calls history.append() directly — and its call
    // site is a write callback, where an escape leaves xterm's write buffer
    // undrained and every later frame frozen with no error on it.
    const history = failingHistory({ append: true });
    const host = new TerminalFrameSource(20, 6, history);
    sources.push(host);
    host.feed("L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6");
    await host.settle();

    host.resize(20, 3);
    expect(await settles(host)).toBe(true);
    // The rows the shrink evicted are gone either way and their count is no
    // longer recoverable, so this reports a hole rather than a clean resize.
    expect(host.historyStatus.degraded).toBe(true);
    expect(host.historyStatus.gaps).toBeGreaterThan(0);

    host.feed("\r\nstill parsing");
    await host.settle();
    expect(host.capture(0)).not.toBeNull();
    expect(host.visibleLines().join("\n")).toContain("still parsing");
  });

  test("dispose survives a history that cannot flush", () => {
    // TerminalManager disposes every screen in one bare loop, so a throw here
    // would abandon the loop and leak every xterm instance behind this one.
    const host = new TerminalFrameSource(20, 6, failingHistory({ flush: true }));
    host.feed("work");
    expect(() => host.dispose()).not.toThrow();
    expect(host.isDisposed).toBe(true);
  });
});
