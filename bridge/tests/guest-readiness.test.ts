import { describe, expect, test } from "bun:test";
import { GuestReadiness } from "../src/submit-gate";

/** The startup Claude Code actually emits, measured: a pre-TUI phase that turns
 *  bracketed paste on and paints nothing, a teardown, then the real mount. */
const PRE_TUI = "\x1b[?25l\x1b[?2004h\x1b[?2031h\x1b[?1004h\x1b[<u\x1b[>5u\x1b[>4;2m";
const QUERY = "\x1b[>0q";
const TEARDOWN = "\x1b[>4m\x1b[<u\x1b[?2031l\x1b[?2004l";
const MOUNT = "\x1b[?2004h\x1b[?2031h\x1b[?1004h\x1b[<u\x1b[>5u\x1b[>4;2m";
const FRAME = "\x1b[?2026h\x1b[?2026l\x1b[38;2;215;119;87m ▐\x1b[m\x1b[1m\x1b[3CClaude\x1b[1CCode";

describe("GuestReadiness", () => {
  test("a guest that has only announced modes is not ready", () => {
    const r = new GuestReadiness();
    expect(r.observe(true, PRE_TUI)).toBe(false);
    expect(r.observe(true, QUERY)).toBe(false);
  });

  test("the frame a mounted TUI paints is what says it is reading", () => {
    const r = new GuestReadiness();
    r.observe(true, PRE_TUI);
    r.observe(true, QUERY);
    r.observe(false, TEARDOWN);
    expect(r.observe(true, MOUNT)).toBe(false);
    expect(r.observe(true, FRAME)).toBe(true);
  });

  test("paint without the mode is not readiness", () => {
    // A shell echoing its prompt reads every newline as Enter; the paste
    // decision and this one have to agree about the guest.
    const r = new GuestReadiness();
    expect(r.observe(false, "user@host:~$ ")).toBe(false);
  });

  test("a sequence split across chunks is not read as text", () => {
    // The half that would false-positive on its own: `1h\x1b[?1004h` opens with
    // two printable characters and paints nothing.
    const r = new GuestReadiness();
    expect(r.observe(true, "\x1b[?2004h\x1b[?203")).toBe(false);
    expect(r.observe(true, "1h\x1b[?1004h")).toBe(false);
    expect(r.observe(true, "hello")).toBe(true);
  });

  test("an OSC title is not paint", () => {
    // The guest sets its window title before it has drawn anything, and an OSC
    // body is printable text that never reaches the grid.
    const r = new GuestReadiness();
    expect(r.observe(true, "\x1b]0;✳ Claude Code\x07")).toBe(false);
    expect(r.observe(true, "\x1b]0;still starting\x1b\\")).toBe(false);
  });

  test("an OSC split across chunks does not leak its body", () => {
    const r = new GuestReadiness();
    expect(r.observe(true, "\x1b]0;Claude")).toBe(false);
    expect(r.observe(true, " Code\x07")).toBe(false);
  });

  test("readiness is not reported twice, and a new interface has to earn it", () => {
    const r = new GuestReadiness();
    r.observe(true, MOUNT);
    expect(r.observe(true, FRAME)).toBe(true);
    expect(r.observe(true, FRAME)).toBe(false);
    // The guest handed the terminal to something else and took it back.
    expect(r.observe(false, TEARDOWN)).toBe(false);
    expect(r.observe(true, MOUNT)).toBe(false);
    expect(r.observe(true, FRAME)).toBe(true);
  });

  test("control characters alone are not paint", () => {
    const r = new GuestReadiness();
    expect(r.observe(true, "\r\n\t\x07")).toBe(false);
  });
});
