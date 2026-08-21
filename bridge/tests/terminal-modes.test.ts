import { describe, test, expect } from "bun:test";
import { TerminalModeTracker } from "../src/terminal-modes";
import { ScrollbackBuffer } from "../src/scrollback";

const ESC = "\x1b";

describe("TerminalModeTracker", () => {
  test("latches the modes a TUI sets at startup", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1049h${ESC}[?1000h${ESC}[?1006h${ESC}[?2004h`);
    expect(t.prelude()).toBe(`${ESC}[?1049h${ESC}[?1000h${ESC}[?1006h${ESC}[?2004h`);
  });

  test("reads multi-parameter DECSET", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1000;1002;1003;1006h`);
    expect(t.prelude()).toBe(
      `${ESC}[?1000h${ESC}[?1002h${ESC}[?1003h${ESC}[?1006h`,
    );
  });

  test("DECRST replaces the latch rather than clearing it", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1000h`);
    t.feed(`${ESC}[?1000l`);
    expect(t.prelude()).toBe(`${ESC}[?1000l`);
  });

  test("resolves a sequence split across chunks", () => {
    const t = new TerminalModeTracker();
    t.feed(`noise${ESC}[?10`);
    t.feed(`00h more`);
    expect(t.prelude()).toBe(`${ESC}[?1000h`);
  });

  test("resolves a sequence split one byte at a time", () => {
    const t = new TerminalModeTracker();
    for (const ch of `${ESC}[?1006h`) t.feed(ch);
    expect(t.prelude()).toBe(`${ESC}[?1006h`);
  });

  test("carries nothing across a non-DECSET escape", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}]0;title`);
    t.feed(`${ESC}[?1000h`);
    expect(t.prelude()).toBe(`${ESC}[?1000h`);
  });

  test("ignores modes that must not be replayed", () => {
    const t = new TerminalModeTracker();
    // 2026 brackets one frame; replaying its set half would wedge the renderer.
    t.feed(`${ESC}[?2026h${ESC}[?2027h${ESC}[?7l`);
    expect(t.prelude()).toBe("");
  });

  test("alt-screen leads the prelude", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1000h${ESC}[?25l${ESC}[?1049h`);
    expect(t.prelude().indexOf(`${ESC}[?1049h`)).toBe(0);
  });

  test("emits nothing when the program set no tracked mode", () => {
    const t = new TerminalModeTracker();
    t.feed("plain output, no escapes at all\r\n");
    expect(t.prelude()).toBe("");
  });

  test("restores mouse reporting the scrollback window has dropped", () => {
    // The shipped regression: Claude Code emits ESC[?1000h + ESC[?1006h once at
    // startup, then redraws until that burst falls out of the 10k tail — after
    // which a reattaching app was told nothing about mouse mode and dropped
    // every click.
    const tracker = new TerminalModeTracker();
    const buffer = new ScrollbackBuffer();

    const startup = `${ESC}[?1049h${ESC}[?1000h${ESC}[?1006h`;
    tracker.feed(startup);
    buffer.append(startup);

    for (let i = 0; i < 400; i++) {
      const frame = `${ESC}[?2026h${ESC}[?25l${ESC}[2J frame ${i} `.padEnd(60, ".") + `${ESC}[?25h${ESC}[?2026l\r\n`;
      tracker.feed(frame);
      buffer.append(frame);
    }

    const tail = buffer.getContents();
    expect(tail).not.toContain(`${ESC}[?1000h`);

    const replay = tracker.prelude() + tail;
    expect(replay).toContain(`${ESC}[?1000h`);
    expect(replay).toContain(`${ESC}[?1006h`);
    expect(replay).toContain(`${ESC}[?1049h`);
    // Per-frame modes still resolve from the tail, which lands after the prelude.
    expect(replay.indexOf(`${ESC}[?1000h`)).toBeLessThan(replay.indexOf(tail.slice(0, 20)));
  });
});
