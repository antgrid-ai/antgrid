import { describe, test, expect } from "bun:test";
import { TRACKED_MODES, TerminalModeTracker } from "../src/terminal-modes";
import { TerminalScreen } from "../src/terminal-screen";

const ESC = "\x1b";

describe("TerminalModeTracker", () => {
  test("latches the modes a TUI sets at startup", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1049h${ESC}[?1000h${ESC}[?1006h${ESC}[?2004h`);
    expect(t.supplementalPrelude())
      .toBe(`${ESC}[?1000h${ESC}[?1006h${ESC}[?2004h`);
  });

  test("reads multi-parameter DECSET", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1000;1002;1003;1006;1016h`);
    expect(t.supplementalPrelude())
      .toBe(`${ESC}[?1000h${ESC}[?1002h${ESC}[?1003h${ESC}[?1006h${ESC}[?1016h`);
  });

  test("DECRST replaces the latch rather than clearing it", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1006h`);
    t.feed(`${ESC}[?1006l`);
    expect(t.supplementalPrelude()).toBe(`${ESC}[?1006l`);
  });

  test("replays in last-write order, not numeric order", () => {
    // `?1000`/`?1002`/`?1003` are one tracking protocol in a VT engine, so the
    // order the guest moved through them is what decides where it ends up:
    // 1002 then 1000 is VT200, and numeric order would replay it as drag.
    const t = new TerminalModeTracker();
    t.feed(`${ESC}[?1002h${ESC}[?1000h`);
    expect(t.supplementalPrelude()).toBe(`${ESC}[?1002h${ESC}[?1000h`);

    // Re-setting a mode moves it to the end, or a Map that keeps first-insert
    // position would replay the transitions in the wrong order.
    t.feed(`${ESC}[?1002h`);
    expect(t.supplementalPrelude()).toBe(`${ESC}[?1000h${ESC}[?1002h`);
  });

  test("resolves a sequence split across chunks", () => {
    const t = new TerminalModeTracker();
    t.feed(`noise${ESC}[?10`);
    t.feed(`06h more`);
    expect(t.supplementalPrelude()).toBe(`${ESC}[?1006h`);
  });

  test("resolves a sequence split one byte at a time", () => {
    const t = new TerminalModeTracker();
    for (const ch of `${ESC}[?1006h`) t.feed(ch);
    expect(t.supplementalPrelude()).toBe(`${ESC}[?1006h`);
  });

  test("carries nothing across a non-DECSET escape", () => {
    const t = new TerminalModeTracker();
    t.feed(`${ESC}]0;title`);
    t.feed(`${ESC}[?1006h`);
    expect(t.supplementalPrelude()).toBe(`${ESC}[?1006h`);
  });

  test("ignores modes that must not be replayed", () => {
    const t = new TerminalModeTracker();
    // 2026 brackets one frame; replaying its set half would wedge the renderer.
    t.feed(`${ESC}[?2026h${ESC}[?2027h${ESC}[?7l`);
    expect(t.supplementalPrelude()).toBe("");
  });

  test("emits nothing when the program set no tracked mode", () => {
    const t = new TerminalModeTracker();
    t.feed("plain output, no escapes at all\r\n");
    expect(t.supplementalPrelude()).toBe("");
  });

  test("emits every latched mode, and never the alt screen", () => {
    const t = new TerminalModeTracker();
    for (const mode of TRACKED_MODES) t.feed(`${ESC}[?${mode}h`);

    expect(t.supplementalPrelude()).toBe(
      [...TRACKED_MODES].filter((m) => m !== 1049).map((m) => `${ESC}[?${m}h`).join(""),
    );
    // A second `?1049h` after the blob re-saves the cursor and re-clears the
    // alternate buffer the blob just filled.
    expect(t.supplementalPrelude()).not.toContain("1049");
  });
});

describe("mode composition with @xterm/addon-serialize", () => {
  test("the composed attach sequence carries every mode the program set", async () => {
    // The shipped regression, in its post-emulator shape: Claude Code emits
    // ESC[?1000h + ESC[?1006h once at startup and then redraws forever. The
    // screen the serializer produces knows nothing about 1006, so only the
    // supplement appended after it tells a returning app how to encode a click.
    const tracker = new TerminalModeTracker();
    const screen = new TerminalScreen(80, 24);
    const startup = `${ESC}[?1049h${ESC}[?1000h${ESC}[?1006h`;
    tracker.feed(startup);
    screen.feed(startup);
    for (let i = 0; i < 400; i++) {
      const frame = `${ESC}[H${ESC}[2J frame ${i} `.padEnd(60, ".") + "\r\n";
      tracker.feed(frame);
      screen.feed(frame);
    }

    const blob = await screen.snapshot();
    expect(blob).not.toContain(`${ESC}[?1006h`);

    const attach = blob + tracker.supplementalPrelude();
    expect(attach).toContain(`${ESC}[?1000h`);
    expect(attach).toContain(`${ESC}[?1006h`);
    // Position-safe only because the supplement is appended: the serializer
    // ends its blob with a relative cursor restore.
    expect(attach.indexOf(`${ESC}[?1006h`)).toBeGreaterThan(blob.length - 1);
    screen.dispose();
  });

  test("a mode the guest turned off while the app was away is turned off again", async () => {
    // The serializer has no reset half — it emits a mode only when it is ON —
    // and the app's engine outlives the attach, so an off-transition the app
    // never saw survives in it. A tab left with drag tracking on encodes the
    // next tap as a mouse report and types it at a shell prompt.
    const tracker = new TerminalModeTracker();
    const screen = new TerminalScreen(80, 24);
    const session =
      `${ESC}[?1049h${ESC}[?1002h${ESC}[?1006h${ESC}[?2004h${ESC}[?1h agent running` +
      `${ESC}[?1049l${ESC}[?1002l${ESC}[?1006l${ESC}[?2004l${ESC}[?1lprompt$ `;
    tracker.feed(session);
    screen.feed(session);

    const attach = (await screen.snapshot()) + tracker.supplementalPrelude();
    for (const mode of [1002, 1006, 2004, 1]) {
      expect(attach).toContain(`${ESC}[?${mode}l`);
    }
    screen.dispose();
  });
});
