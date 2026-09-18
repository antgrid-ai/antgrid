import { describe, expect, test } from "bun:test";
import { GuestReadiness } from "../src/submit-gate";
import { BRACKETED_PASTE, TerminalModeTracker } from "../src/terminal-modes";

/** The startup Claude Code actually emits, measured: a pre-TUI phase that turns
 *  bracketed paste on and paints nothing, a teardown, then the real mount. */
const PRE_TUI = "\x1b[?25l\x1b[?2004h\x1b[?2031h\x1b[?1004h\x1b[<u\x1b[>5u\x1b[>4;2m";
const QUERY = "\x1b[>0q";
const TEARDOWN = "\x1b[>4m\x1b[<u\x1b[?2031l\x1b[?2004l";
const MOUNT = "\x1b[?2004h\x1b[?2031h\x1b[?1004h\x1b[<u\x1b[>5u\x1b[>4;2m";
const FRAME = "\x1b[?2026h\x1b[?2026l\x1b[38;2;215;119;87m ▐\x1b[m\x1b[1m\x1b[3CClaude\x1b[1CCode";

/** The guest's output read the way `terminal-manager.ts` reads it: one tracker
 *  and one readiness, fed the same chunk in the same order. The ordering is half
 *  of what is under test, so the tests must not restate it. */
function guest(): (chunk: string) => "ready" | "lost" | null {
  const modes = new TerminalModeTracker();
  const readiness = new GuestReadiness();
  return (chunk) => {
    const moved = modes.feed(chunk);
    return readiness.observe(chunk, {
      on: modes.isSet(BRACKETED_PASTE),
      changed: moved.has(BRACKETED_PASTE),
    });
  };
}

describe("GuestReadiness", () => {
  test("a guest that has only announced modes is not ready", () => {
    const g = guest();
    expect(g(PRE_TUI)).toBe(null);
    expect(g(QUERY)).toBe(null);
  });

  test("the frame a mounted TUI paints is what says it is reading", () => {
    const g = guest();
    g(PRE_TUI);
    g(QUERY);
    g(TEARDOWN);
    expect(g(MOUNT)).toBe(null);
    expect(g(FRAME)).toBe("ready");
  });

  test("paint in the chunk that turns the mode on is not readiness", () => {
    // A PTY splits where it likes, so the pre-TUI banner and the mode that
    // follows it arrive together. The paint is on the wrong side of the
    // announcement and belongs to no interface that has mounted.
    const g = guest();
    expect(g(`Welcome to Claude Code\r\n${PRE_TUI}`)).toBe(null);
    expect(g(QUERY)).toBe(null);
    expect(g(FRAME)).toBe("ready");
  });

  test("paint without the mode is not readiness", () => {
    // A shell echoing its prompt reads every newline as Enter; the paste
    // decision and this one have to agree about the guest.
    const g = guest();
    expect(g("user@host:~$ ")).toBe(null);
  });

  test("the interface going away retracts readiness", () => {
    const g = guest();
    g(MOUNT);
    expect(g(FRAME)).toBe("ready");
    expect(g(TEARDOWN)).toBe("lost");
    expect(g(MOUNT)).toBe(null);
    expect(g(FRAME)).toBe("ready");
  });

  test("a mode restated while it is already on does not disturb readiness", () => {
    // A TUI that reasserts its modes each frame would otherwise lose and regain
    // its reader on every repaint.
    const g = guest();
    g(MOUNT);
    expect(g(FRAME)).toBe("ready");
    expect(g(`\x1b[?2004h${FRAME}`)).toBe(null);
  });

  test("a sequence split across chunks is not read as text", () => {
    // The half that would false-positive on its own: `1h\x1b[?1004h` opens with
    // two printable characters and paints nothing.
    const g = guest();
    expect(g("\x1b[?2004h\x1b[?203")).toBe(null);
    expect(g("1h\x1b[?1004h")).toBe(null);
    expect(g("hello")).toBe("ready");
  });

  test("an OSC title is not paint", () => {
    // The guest sets its window title before it has drawn anything, and an OSC
    // body is printable text that never reaches the grid.
    const g = guest();
    g(MOUNT);
    expect(g("\x1b]0;✳ Claude Code\x07")).toBe(null);
    expect(g("\x1b]0;still starting\x1b\\")).toBe(null);
  });

  test("an OSC split across chunks does not leak its body", () => {
    const g = guest();
    g(MOUNT);
    expect(g("\x1b]0;Claude")).toBe(null);
    expect(g(" Code\x07")).toBe(null);
  });

  test("readiness is reported once and stands until the mode goes", () => {
    const g = guest();
    g(MOUNT);
    expect(g(FRAME)).toBe("ready");
    expect(g(FRAME)).toBe(null);
  });

  test("a mount and its first frame in one read is readiness", () => {
    // A PTY coalesces writes microseconds apart, and a TUI that mounts and
    // paints together then waits for input sends nothing else to be believed
    // on. Discarding this chunk is not one chunk of latency, it is forever.
    const g = guest();
    expect(g(`${MOUNT}${FRAME}`)).toBe("ready");
  });

  test("a mode dropped and retaken in one read costs readiness until the repaint", () => {
    // The modal case, coalesced: the mode ends the chunk on, but nothing has
    // painted since it came back, so the new interface has not vouched for
    // itself yet.
    const g = guest();
    g(MOUNT);
    expect(g(FRAME)).toBe("ready");
    expect(g(`${TEARDOWN}${MOUNT}`)).toBe("lost");
    expect(g(FRAME)).toBe("ready");
  });

  test("a chunk discarded as ambiguous still advances the parser", () => {
    // Skipping the scan on the chunk that moved the mode would leave the split
    // CSI below resolving against the next chunk's bytes, and `1h` would read
    // as paint.
    const g = guest();
    expect(g("\x1b[?2004h\x1b[?203")).toBe(null);
    expect(g("1h")).toBe(null);
  });

  test("control characters alone are not paint", () => {
    const g = guest();
    g(MOUNT);
    expect(g("\r\n\t\x07")).toBe(null);
  });
});
