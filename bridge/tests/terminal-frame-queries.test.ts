import { describe, expect, test } from "bun:test";
import { Terminal } from "@xterm/headless";
import { installTerminalQueries } from "../src/terminal-frames/queries";
import { XtermFrameAdapter } from "../src/terminal-frames/xterm-adapter";
import { VtCapabilityResponder } from "../src/vt-capability-responder";

const COLORS = {
  foreground: "rgb:fafa/fafa/fafa",
  background: "rgb:0909/0909/0b0b",
  cursor: "rgb:8181/8c8c/f8f8",
};

/** The bytes vt-capability-responder.ts answers today. Pinned as literals, not
 *  derived: a change on either side must fail here rather than agree quietly. */
const DA1 = "\x1b[?64;1;2;6;9;15;18;21;22c";
const DA2 = "\x1b[>1;1000;0c";
const DA3 = "\x1bP!|00000000\x1b\\";
const XTVERSION = "\x1bP>|antgrid(1.0)\x1b\\";

interface Harness {
  term: Terminal;
  /** What the bridge writes back to the PTY. */
  replies: string[];
  /** What xterm itself would have replied — never forwarded. */
  xtermSaid: string[];
  write(data: string): Promise<void>;
  detach(): void;
}

function harness(
  opts: {
    cols?: number; rows?: number; keyboardFlags?: number;
    /** Stands in for a PTY that has gone away under the parser. */
    onReply?: (data: string) => void;
  } = {},
): Harness {
  const term = new Terminal({
    cols: opts.cols ?? 80,
    rows: opts.rows ?? 10,
    allowProposedApi: true,
  });
  const replies: string[] = [];
  const xtermSaid: string[] = [];
  term.onData((data) => xtermSaid.push(data));
  // The real adapter, not a stub: the margins CPR is relative to are private
  // xterm state, and reading them anywhere else is what this is checking.
  const adapter = new XtermFrameAdapter(term);
  const detach = installTerminalQueries(
    term,
    (data) => { replies.push(data); opts.onReply?.(data); },
    () => opts.keyboardFlags ?? 0,
    () => adapter.margins().top,
    COLORS,
  );
  return {
    term,
    replies,
    xtermSaid,
    write: (data) => new Promise<void>((resolve) => term.write(data, resolve)),
    detach,
  };
}

describe("terminal frame queries", () => {
  test("answers the audited queries with the byte responder's exact bytes", async () => {
    const h = harness();
    await h.write("\x1b[c\x1b[0c\x1b[>c\x1b[>0c\x1b[=c\x1b[=0c\x1b[>q\x1b[>0q\x1b[5n\x1b[?u");
    expect(h.replies).toEqual([
      DA1, DA1, DA2, DA2, DA3, DA3, XTVERSION, XTVERSION, "\x1b[0n", "\x1b[?0u",
    ]);
  });

  test("reports the kitty flags the source tracks", async () => {
    const h = harness({ keyboardFlags: 5 });
    await h.write("\x1b[?u");
    expect(h.replies).toEqual(["\x1b[?5u"]);
  });

  test("leaves a device attributes request with a non-default parameter alone", async () => {
    const h = harness();
    await h.write("\x1b[1c\x1b[>2c\x1b[>1q");
    expect(h.replies).toEqual([]);
    expect(h.xtermSaid).toEqual([]);
  });

  test("never forwards a reply xterm generated on its own", async () => {
    const h = harness();
    // DECRQSS: xterm fabricates an SGR reply from a screen model this bridge
    // does not have. vt-capability-responder.ts refuses it on purpose.
    await h.write("\x1b[1;4;38;5;196m\x1bP$qm\x1b\\");
    expect(h.replies).toEqual([]);
    expect(h.xtermSaid.join("")).toContain("$r");
  });

  test("refuses the queries the byte responder refuses", async () => {
    const h = harness();
    await h.write("\x1bP$qm\x1b\\"); // DECRQSS — current SGR
    await h.write("\x1bP$q r\x1b\\"); // DECRQSS — DECSTBM
    await h.write("\x1b]4;1;?\x07"); // OSC 4 — palette
    await h.write("\x1b[?6n"); // DECXCPR
    await h.write("\x1bP+q544e\x1b\\"); // XTGETTCAP
    await h.write("\x1b[18t\x1b[14t"); // XTWINOPS
    await h.write("\x1b[0n\x1b[3n"); // DSR forms with no audited answer
    expect(h.replies).toEqual([]);
  });

  test("answers colors at their parser position among cursor queries", async () => {
    const h = harness();
    await h.write("\x1b[4;7H\x1b]10;?\x07\x1b[6n\x1b]11;?\x1b\\\x1b]12;?\x07");
    expect(h.replies).toEqual([
      `\x1b]10;${COLORS.foreground}\x07`, "\x1b[4;7R",
      `\x1b]11;${COLORS.background}\x07`, `\x1b]12;${COLORS.cursor}\x07`,
    ]);
  });

  test("DECRQM answers exactly what the byte responder answers", async () => {
    const h = harness();
    const byteResponder = new VtCapabilityResponder(COLORS);
    const modes = [1, 7, 25, 66, 1000, 1049, 2004, 2026, 2027, 2031, 9999];
    const guest = "\x1b[?1000;1006h\x1b[?7l\x1b[?2004h\x1b[?2004l\x1b[?2026h";

    await h.write(guest);
    byteResponder.feed(guest);
    for (const mode of modes) {
      await h.write(`\x1b[?${mode}$p`);
      expect(byteResponder.feed(`\x1b[?${mode}$p`)).toBe(h.replies.at(-1)!);
    }
    // Pinned so the differential above cannot pass by both sides going silent.
    expect(h.replies[0]).toBe("\x1b[?1;2$y");
    expect(h.replies).toHaveLength(modes.length);
  });

  for (const [name, reset] of [["DECSTR", "\x1b[!p"], ["RIS", "\x1bc"]] as const) {
    test(`DECRQM follows the reset ${name} performs, unlike the byte responder alone`, async () => {
      // The byte responder's own scan of the guest's bytes never observes
      // DECSTR or RIS — neither emits the `CSI ? Pm h|l` it watches for — so
      // asking IT alone would still report the mode set. queries.ts reads
      // xterm's own live state for a tracked mode instead, which the two
      // do NOT agree on here, unlike the untouched case above.
      const h = harness();
      const byteResponder = new VtCapabilityResponder(COLORS);
      await h.write(`\x1b[?2004h${reset}\x1b[?2004$p`);
      byteResponder.feed(`\x1b[?2004h${reset}`);
      expect(byteResponder.feed("\x1b[?2004$p")).toBe("\x1b[?2004;1$y");
      expect(h.replies).toEqual(["\x1b[?2004;2$y"]);
    });
  }

  test("DECRQM for cursor visibility follows DECSTR, unlike the byte responder alone", async () => {
    const h = harness();
    const byteResponder = new VtCapabilityResponder(COLORS);
    const guest = "\x1b[?25l\x1b[!p"; // hide the cursor, then soft-reset
    await h.write(guest);
    byteResponder.feed(guest);
    await h.write("\x1b[?25$p");
    // The byte scan never observes DECSTR, so it still thinks the cursor is
    // hidden; queries.ts reads xterm's own live cursor-visibility flag instead.
    expect(byteResponder.feed("\x1b[?25$p")).toBe("\x1b[?25;2$y");
    expect(h.replies.at(-1)).toBe("\x1b[?25;1$y");
  });

  test("DECRQM for SGR mouse encoding follows xterm's single active encoding, not the byte scan's independent bits", async () => {
    const h = harness();
    const byteResponder = new VtCapabilityResponder(COLORS);
    // xterm tracks ONE active mouse encoding: enabling 1016 (SGR-pixels)
    // silently deactivates 1006 (SGR) underneath it, with no `l` for 1006
    // the byte scan could observe — it still thinks both are set.
    const guest = "\x1b[?1006h\x1b[?1016h";
    await h.write(guest);
    byteResponder.feed(guest);
    await h.write("\x1b[?1006$p");
    expect(byteResponder.feed("\x1b[?1006$p")).toBe("\x1b[?1006;1$y");
    expect(h.replies.at(-1)).toBe("\x1b[?1006;2$y");
  });

  test("DECRQM for SGR mouse encoding follows the guest's own RIS reset", async () => {
    const h = harness();
    // RIS resets xterm's tracked mouse encoding to DEFAULT (measured against
    // the real engine); the byte scan has no way to observe that either.
    await h.write("\x1b[?1006h\x1bc\x1b[?1006$p");
    expect(h.replies).toEqual(["\x1b[?1006;2$y"]);
  });

  test("RIS resets the byte responder's own tracked modes for what liveDecMode cannot cover", async () => {
    // 2027/2031 have no live xterm state to read (unlike 25/1006/1016 above),
    // so they stay on the byte scan — which never sees an ESC sequence at
    // all. Without an explicit reset hook they would answer SET forever once
    // the guest turned them on, regardless of an intervening RIS.
    const h = harness();
    await h.write("\x1b[?2027h\x1b[?2031h\x1bc\x1b[?2027$p\x1b[?2031$p");
    expect(h.replies).toEqual(["\x1b[?2027;2$y", "\x1b[?2031;2$y"]);
  });

  test("CPR reports the real cursor, not the byte responder's guess", async () => {
    const h = harness();
    await h.write("\x1b[5;9H\x1b[6n");
    expect(h.replies).toEqual(["\x1b[5;9R"]);
    expect(new VtCapabilityResponder(COLORS).feed("\x1b[6n")).toBe("\x1b[1;1R");
  });

  test("CPR observes the output before it, not later bytes in the same chunk", async () => {
    const h = harness();
    await h.write("A\x1b[6n\x1b[10;20H");
    expect(h.replies).toEqual(["\x1b[1;2R"]);
  });

  test("CPR clamps a pending wrap to the last column", async () => {
    // The standard grapheme-width probe: write, then read the cursor back.
    // xterm parks the cursor at `cols` while the wrap is pending.
    const h = harness({ cols: 80 });
    await h.write("x".repeat(80) + "\x1b[6n");
    expect(h.replies).toEqual(["\x1b[1;80R"]);
  });

  test("CPR is DECOM-relative inside a scroll region", async () => {
    const h = harness({ cols: 20, rows: 6 });
    await h.write("\x1b[2;5r\x1b[?6h\x1b[1;1H\x1b[6n");
    // The cursor sits on absolute row 2; origin mode makes that row 1.
    expect(h.term.buffer.active.cursorY).toBe(1);
    expect(h.replies).toEqual(["\x1b[1;1R"]);
    await h.write("\x1b[3;2H\x1b[6n");
    expect(h.term.buffer.active.cursorY).toBe(3);
    expect(h.replies.at(-1)).toBe("\x1b[3;2R");
  });

  test("CPR reports absolutely with origin mode off", async () => {
    const h = harness({ cols: 20, rows: 6 });
    await h.write("\x1b[2;5r\x1b[3;2H\x1b[6n");
    expect(h.term.buffer.active.cursorY).toBe(2);
    expect(h.replies).toEqual(["\x1b[3;2R"]);
  });

  test("CPR ignores a scroll region xterm itself rejected", async () => {
    const h = harness({ cols: 20, rows: 6 });
    await h.write("\x1b[5;2r\x1b[?6h\x1b[3;1H\x1b[6n");
    expect(h.replies).toEqual(["\x1b[3;1R"]);
  });

  test("CPR follows the margin reset a resize performs", async () => {
    const h = harness({ cols: 20, rows: 6 });
    await h.write("\x1b[3;5r\x1b[?6h");
    h.term.resize(20, 12);
    await h.write("\x1b[4;1H\x1b[6n");
    expect(h.replies).toEqual(["\x1b[4;1R"]);
  });

  for (const [name, reset] of [["DECSTR", "\x1b[!p"], ["RIS", "\x1bc"]] as const) {
    test(`CPR follows the margin reset ${name} performs`, async () => {
      const h = harness({ cols: 20, rows: 6 });
      await h.write(`\x1b[3;5r${reset}\x1b[?6h\x1b[4;1H\x1b[6n`);
      expect(h.replies).toEqual(["\x1b[4;1R"]);
    });
  }

  test("stops answering once detached", async () => {
    const h = harness();
    h.detach();
    await h.write("\x1b[c\x1b[6n\x1b[?u\x1b[5n");
    expect(h.replies).toEqual([]);
  });

  test("a reply the PTY refuses does not stop the parser", async () => {
    // `reply` runs inside xterm's parse loop, which retires neither the escape
    // it is answering nor the chunk carrying it until the handler returns — so
    // a throw here freezes the terminal for the rest of the process.
    const h = harness({ cols: 20, rows: 4, onReply: () => { throw new Error("pty gone"); } });
    const settled = await Promise.race([
      h.write("before\x1b[6n\x1b[cafter").then(() => true),
      new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 250)),
    ]);
    expect(settled).toBe(true);
    expect(h.term.buffer.active.getLine(0)?.translateToString(true)).toBe("beforeafter");
  });

  for (const [label, input, expected] of [
    // The alternate screen has its own margins, and neither buffer's survive a
    // switch — a region a shell set on the primary must not offset a CPR the
    // TUI on the alternate screen asks for, in either direction.
    ["a region set on the primary does not follow the guest to the alternate",
      "\x1b[2;6r\x1b[?1049h\x1b[?6h\x1b[3;5H\x1b[6n", "\x1b[3;5R"],
    ["a region set on the alternate does not follow it back to the primary",
      "\x1b[2;6r\x1b[?1049h\x1b[4;7r\x1b[?1049l\x1b[?6h\x1b[3;3H\x1b[6n", "\x1b[3;3R"],
    ["a primary with no region is not offset by the alternate's",
      "\x1b[?1049h\x1b[4;7r\x1b[?6h\x1b[?1049l\x1b[3;2H\x1b[6n", "\x1b[3;2R"],
    ["the alternate's own region is what its own CPR is relative to",
      "\x1b[2;6r\x1b[?1049h\x1b[4;7r\x1b[?6h\x1b[3;3H\x1b[6n", "\x1b[3;3R"],
  ] as const) {
    test(`origin-mode CPR is relative to the active buffer's region: ${label}`, async () => {
      const h = harness({ cols: 20, rows: 8 });
      await h.write(input);
      expect(h.replies).toEqual([expected]);
    });
  }

  test("query acceptance follows xterm's own parameter rule, not the byte responder's", async () => {
    // xterm answers whenever the leading parameter is absent or 0 and ignores
    // what follows it; vt-capability-responder.ts matches whole byte strings, so
    // it is silent on every form below. Answering is the xterm-correct half, and
    // the divergence is pinned here rather than left to be discovered on
    // promotion.
    for (const [input, expected] of [
      ["\x1b[;1c", DA1], ["\x1b[0:1c", DA1], ["\x1b[0;0c", DA1], ["\x9bc", DA1],
      ["\x1b[>0;1c", DA2], ["\x1b[=;1c", DA3], ["\x1b[>0;1q", XTVERSION],
      ["\x1b[5;1n", "\x1b[0n"], ["\x1b[?7;25$p", "\x1b[?7;1$y"],
    ] as const) {
      const h = harness({ cols: 20, rows: 4 });
      await h.write(input);
      expect(h.replies).toEqual([expected]);
      expect(new VtCapabilityResponder(COLORS).feed(input)).toBe("");
      h.detach();
    }
  });

  test("plain output produces nothing", async () => {
    const h = harness();
    await h.write("just some text\r\n\x1b[32mgreen\x1b[0m\r\n");
    expect(h.replies).toEqual([]);
  });
});
