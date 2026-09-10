import { describe, expect, test } from "bun:test";
import { Terminal } from "@xterm/headless";
import { installTerminalQueries } from "../src/terminal-frames/queries";
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
  opts: { cols?: number; rows?: number; keyboardFlags?: number } = {},
): Harness {
  const term = new Terminal({
    cols: opts.cols ?? 80,
    rows: opts.rows ?? 10,
    allowProposedApi: true,
  });
  const replies: string[] = [];
  const xtermSaid: string[] = [];
  term.onData((data) => xtermSaid.push(data));
  const detach = installTerminalQueries(
    term,
    (data) => replies.push(data),
    () => opts.keyboardFlags ?? 0,
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

  test("leaves OSC colour queries to the byte-level responder", async () => {
    // Both terminators reach the same payload here, so answering at the parser
    // would have to guess one; a guest reading until BEL never sees an ST.
    const h = harness();
    await h.write("\x1b]10;?\x07\x1b]11;?\x1b\\\x1b]12;?\x07");
    expect(h.replies).toEqual([]);

    const byteResponder = new VtCapabilityResponder(COLORS);
    expect(byteResponder.feed("\x1b]11;?\x07")).toBe(`\x1b]11;${COLORS.background}\x07`);
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

  test("DECRQM keeps answering a recognised mode after a reset", async () => {
    // Mode state is the byte responder's, and it does not drop it on a RIS.
    // Both responders must therefore still agree once the guest resets.
    const h = harness();
    const byteResponder = new VtCapabilityResponder(COLORS);
    await h.write("\x1b[?2004h\x1bc\x1b[?2004$p");
    byteResponder.feed("\x1b[?2004h\x1bc");
    expect(h.replies).toEqual([byteResponder.feed("\x1b[?2004$p")]);
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

  test("plain output produces nothing", async () => {
    const h = harness();
    await h.write("just some text\r\n\x1b[32mgreen\x1b[0m\r\n");
    expect(h.replies).toEqual([]);
  });
});
