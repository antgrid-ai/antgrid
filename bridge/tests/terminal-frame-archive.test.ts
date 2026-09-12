import { afterEach, describe, expect, test } from "bun:test";
import { Terminal } from "@xterm/headless";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { XtermFrameAdapter, type TerminalArchiveSink } from "../src/terminal-frames/xterm-adapter";
import {
  TerminalHistoryRowSchema,
  type TerminalHistoryBoundary, type TerminalHistoryRow,
} from "../src/terminal-frames/protocol";
import type { TerminalRunHistory } from "../src/terminal-frames/history";

/**
 * Stands in for the SQLite-backed run history so a test can assert on the rows
 * the source hands it, in eviction order. It validates each row on the way in,
 * so a hook that reports a shape the real store would reject fails here too.
 */
class RecordingHistory {
  readonly rows: TerminalHistoryRow[] = [];
  private epoch = 0;
  private nextRowId = 0;

  append(row: Omit<TerminalHistoryRow, "rowId">): void {
    this.rows.push(TerminalHistoryRowSchema.parse({ ...row, rowId: this.nextRowId++ }));
  }
  flush(): void {}
  clear(): void {
    this.epoch++;
    this.nextRowId = 0;
    this.rows.length = 0;
  }
  boundary(): TerminalHistoryBoundary {
    return {
      epoch: this.epoch, firstRowId: this.rows[0]?.rowId ?? this.nextRowId,
      nextRowId: this.nextRowId, status: "recording",
    };
  }
  /** Archived rows as trimmed text, which is what an eviction assertion is about. */
  get text(): string[] {
    return this.rows.map((row) => row.spans.map((span) => span.text).join("").trimEnd());
  }
}

interface Recorder { source: TerminalFrameSource; history: RecordingHistory }
const sources: TerminalFrameSource[] = [];
function recorder(cols = 20, rows = 6): Recorder {
  const history = new RecordingHistory();
  const source = new TerminalFrameSource(cols, rows, history as unknown as TerminalRunHistory);
  sources.push(source);
  return { source, history };
}
const SIX_LINES = "L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6";
/** A 20x6 recorder holding L1..L6 with the cursor on the last row and nothing
 *  archived yet — the shape every eviction case below starts from. */
async function filled(): Promise<Recorder> {
  const rec = recorder();
  rec.source.feed(SIX_LINES);
  await rec.source.settle();
  expect(rec.history.rows).toEqual([]);
  return rec;
}
async function feed(rec: Recorder, data: string): Promise<void> {
  rec.source.feed(data);
  await rec.source.settle();
}

/** A terminal with no source over it, for the adapter contracts a source cannot
 *  reach: its own sink cannot throw and it installs exactly one. */
const terminals: Terminal[] = [];
function bare(cols = 20, rows = 3): Terminal {
  const term = new Terminal({ cols, rows, allowProposedApi: true });
  terminals.push(term);
  return term;
}
/** False when the write never parsed — an escape out of the parse loop leaves
 *  the write buffer undrained and no callback ever fires. */
function parses(term: Terminal, data: string): Promise<boolean> {
  return Promise.race([
    new Promise<boolean>((resolve) => term.write(data, () => resolve(true))),
    new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 250)),
  ]);
}
function counting(): TerminalArchiveSink & { rows: number } {
  return { rows: 0, row() { this.rows++; }, gap() {}, discarded() {} };
}
afterEach(() => {
  for (const screen of sources.splice(0)) screen.dispose();
  for (const term of terminals.splice(0)) term.dispose();
});

describe("terminal frame row archive", () => {
  test("ordinary scrolling archives each row as it leaves the viewport", async () => {
    const rec = await filled();
    await feed(rec, "\r\nL7\r\nL8");
    expect(rec.history.text).toEqual(["L1", "L2"]);
    expect(rec.history.rows.map((row) => row.rowId)).toEqual([0, 1]);
    expect(rec.source.visibleLines()).toEqual(["L3", "L4", "L5", "L6", "L7", "L8"]);
    expect(rec.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 0 });
  });

  test("rows trimmed off the end of the emulator's own scrollback were archived on the way in", async () => {
    // The trim is a second BufferService.scroll caller: history must outlive the
    // ring, which is the whole reason it exists.
    const rec = recorder();
    rec.source.setHistoryLimit(2);
    await feed(rec, SIX_LINES + "\r\nL7\r\nL8\r\nL9\r\nL10");
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4"]);
    expect(rec.source.normalHistoryLines()).toHaveLength(8);
  });

  test("CSI S archives out of a top-anchored region and discards out of any other", async () => {
    const anchored = await filled();
    await feed(anchored, "\x1b[2S");
    expect(anchored.history.text).toEqual(["L1", "L2"]);
    expect(anchored.source.historyStatus.discarded).toBe(0);

    const banded = await filled();
    await feed(banded, "\x1b[2;5r\x1b[2S");
    expect(banded.history.text).toEqual([]);
    expect(banded.source.historyStatus.discarded).toBe(2);
    expect(banded.source.historyStatus.degraded).toBe(false);
  });

  test("CSI S counts the region, not the raw parameter", async () => {
    const rec = await filled();
    await feed(rec, "\x1b[99S");
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4", "L5", "L6"]);
    expect(rec.source.visibleLines().join("")).toBe("");
  });

  test("CSI M archives only at the top of a top-anchored region", async () => {
    const top = await filled();
    await feed(top, "\x1b[1;1H\x1b[2M");
    expect(top.history.text).toEqual(["L1", "L2"]);
    expect(top.source.historyStatus.discarded).toBe(0);

    const middle = await filled();
    await feed(middle, "\x1b[3;1H\x1b[2M");
    expect(middle.history.text).toEqual([]);
    expect(middle.source.historyStatus.discarded).toBe(2);
    expect(middle.source.visibleLines()).toEqual(["L1", "L2", "L5", "L6", "", ""]);
  });

  test("ED(2) archives the used rows and never a screenful of blanks", async () => {
    const full = await filled();
    await feed(full, "\x1b[2J");
    expect(full.history.text).toEqual(["L1", "L2", "L3", "L4", "L5", "L6"]);
    expect(full.source.visibleLines().join("")).toBe("");

    const sparse = recorder();
    await feed(sparse, "AA");
    await feed(sparse, "\x1b[2J");
    expect(sparse.history.text).toEqual(["AA"]);

    const empty = recorder();
    await feed(empty, "\x1b[2J");
    expect(empty.history.rows).toEqual([]);
  });

  test("ED(3) clears history and starts a fresh epoch", async () => {
    const rec = await filled();
    await feed(rec, "\r\nL7\r\nL8");
    rec.source.resize(30, 6);
    await rec.source.settle();
    expect(rec.history.text).toEqual(["L1", "L2"]);
    expect(rec.source.capture(0)!.history.epoch).toBe(0);
    expect(rec.source.historyStatus.degraded).toBe(false);

    await feed(rec, "\x1b[3J");
    expect(rec.history.rows).toEqual([]);
    expect(rec.source.capture(50)!.history).toMatchObject({ epoch: 1, firstRowId: 0, nextRowId: 0 });
    // The epoch bump IS the discontinuity signal, so what described the old one
    // must not be reported against the new one.
    expect(rec.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 0 });
  });

  test("DECSED is the same erase and reaches the same archive", async () => {
    // xterm registers eraseInDisplay for `CSI J` and `CSI ? J` alike, so a hook
    // keyed on the bare final let a private-form clear take a screenful of rows
    // with nothing archived and nothing reported as a hole.
    const erased = await filled();
    await feed(erased, "\x1b[?2J");
    expect(erased.history.text).toEqual(["L1", "L2", "L3", "L4", "L5", "L6"]);
    expect(erased.source.visibleLines().join("")).toBe("");

    const cleared = await filled();
    await feed(cleared, "\r\nL7\r\nL8");
    expect(cleared.history.text).toEqual(["L1", "L2"]);
    await feed(cleared, "\x1b[?3J");
    expect(cleared.history.rows).toEqual([]);
    expect(cleared.source.capture(0)!.history.epoch).toBe(1);
  });

  test("rows destroyed at the bottom edge are discarded, never archived", async () => {
    const inserted = await filled();
    await feed(inserted, "\x1b[1;1H\x1b[2L");
    expect(inserted.history.rows).toEqual([]);
    expect(inserted.source.historyStatus.discarded).toBe(2);
    expect(inserted.source.visibleLines()).toEqual(["", "", "L1", "L2", "L3", "L4"]);

    // scrollDown moves the whole region wherever the cursor happens to be, so
    // its loss must not be measured from the cursor. Here it sits on the last
    // row, which once clamped the count to one.
    const scrolled = await filled();
    await feed(scrolled, "\x1b[2T");
    expect(scrolled.history.rows).toEqual([]);
    expect(scrolled.source.historyStatus.discarded).toBe(2);
    expect(scrolled.source.visibleLines()).toEqual(["", "", "L1", "L2", "L3", "L4"]);
  });

  test("reverse index discards only from the top margin", async () => {
    const atTop = await filled();
    await feed(atTop, "\x1b[1;1H\x1bM");
    expect(atTop.source.historyStatus.discarded).toBe(1);
    expect(atTop.history.rows).toEqual([]);
    expect(atTop.source.visibleLines()).toEqual(["", "L1", "L2", "L3", "L4", "L5"]);

    const atRegionTop = await filled();
    await feed(atRegionTop, "\x1b[3;6r\x1b[3;1H\x1bM");
    expect(atRegionTop.source.historyStatus.discarded).toBe(1);
    expect(atRegionTop.source.visibleLines()).toEqual(["L1", "L2", "", "L3", "L4", "L5"]);

    // Anywhere else it only steps the cursor up. Nothing leaves the grid, so
    // nothing may be counted as lost.
    const midScreen = await filled();
    await feed(midScreen, "\x1b[3;1H\x1bM");
    expect(midScreen.source.historyStatus.discarded).toBe(0);
    expect(midScreen.source.visibleLines()).toEqual(["L1", "L2", "L3", "L4", "L5", "L6"]);
  });

  test("DECALN overpaints in place and archives nothing", async () => {
    const rec = await filled();
    await feed(rec, "\x1b#8");
    expect(rec.history.rows).toEqual([]);
    expect(rec.source.historyStatus.discarded).toBe(6);
    expect(rec.source.visibleLines().every((line) => line === "E".repeat(20))).toBe(true);
  });

  test("a row-count shrink archives the rows it evicts", async () => {
    // The repro the hook was validated against and failed: nothing about a
    // resize reaches BufferService.scroll, onScroll or onLineFeed.
    const rec = await filled();
    rec.source.resize(20, 3);
    await rec.source.settle();
    expect(rec.source.visibleLines()).toEqual(["L4", "L5", "L6"]);
    expect(rec.history.text).toEqual(["L1", "L2", "L3"]);
    expect(rec.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 0 });
  });

  test("a shrink against a full emulator ring archives what survived its trim", async () => {
    const rec = recorder();
    rec.source.setHistoryLimit(2);
    await feed(rec, SIX_LINES + "\r\nL7\r\nL8\r\nL9\r\nL10");
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4"]);

    rec.source.resize(20, 3);
    await rec.source.settle();
    // Three rows left the viewport; the ring was already at its ceiling, so it
    // dropped the first inside the same call and kept the other two, leaving
    // baseY where it started and describing neither number. The two still in the
    // ring are archived, the third is the hole, and `degraded` is the part the
    // app acts on.
    expect(rec.source.visibleLines()).toEqual(["L8", "L9", "L10"]);
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4", "L5", "L6", "L7"]);
    expect(rec.source.historyStatus).toMatchObject({ degraded: false, gaps: 0, discarded: 0 });
  });

  test("a deeper shrink against a full ring counts every row it could not keep", async () => {
    const rec = recorder(20, 8);
    rec.source.setHistoryLimit(2);
    await feed(rec, Array.from({ length: 12 }, (_, index) => `L${index + 1}`).join("\r\n"));
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4"]);

    rec.source.resize(20, 2);
    await rec.source.settle();
    // Six rows crossed the top edge and the ring kept two of them. A count fixed
    // at one described this as a single hole while four rows were gone.
    expect(rec.source.visibleLines()).toEqual(["L11", "L12"]);
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4", "L5", "L6", "L7", "L8", "L9", "L10"]);
    expect(rec.source.historyStatus).toMatchObject({ degraded: false, gaps: 0, discarded: 0 });
  });

  test("a shrink with the cursor above the last row reports the rows it destroys", async () => {
    // xterm sheds a row per lost line by popping whatever sits BELOW the cursor,
    // and a pop leaves baseY untouched — so a delta reads it as nothing happening
    // while real content goes off the bottom edge with no scrollback to go to.
    const top = await filled();
    await feed(top, "\x1b[1;1H");
    top.source.resize(20, 3);
    await top.source.settle();
    expect(top.source.visibleLines()).toEqual(["L1", "L2", "L3"]);
    expect(top.history.text).toEqual([]);
    expect(top.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 3 });

    // Mid-screen: the shed rows split between the two edges.
    const middle = await filled();
    await feed(middle, "\x1b[4;1H");
    middle.source.resize(20, 3);
    await middle.source.settle();
    expect(middle.source.visibleLines()).toEqual(["L2", "L3", "L4"]);
    expect(middle.history.text).toEqual(["L1"]);
    expect(middle.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 2 });
  });

  test("a shrink over blank rows below the cursor destroys nothing worth counting", async () => {
    const rec = recorder();
    await feed(rec, "L1\r\nL2");
    rec.source.resize(20, 3);
    await rec.source.settle();
    expect(rec.source.visibleLines()).toEqual(["L1", "L2", ""]);
    expect(rec.history.text).toEqual([]);
    expect(rec.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 0 });
  });

  test("a grow keeps archived rows outside the live viewport", async () => {
    const rec = await filled();
    rec.source.resize(20, 3);
    await rec.source.settle();
    rec.source.resize(20, 6);
    await rec.source.settle();
    expect(rec.source.visibleLines()).toEqual(["L4", "L5", "L6", "", "", ""]);
    expect(rec.history.text).toEqual(["L1", "L2", "L3"]);
    expect(rec.source.capture(0)!.history.nextRowId).toBe(3);

    await feed(rec, "\x1b[6;1H\r\nX1\r\nX2\r\nX3");
    expect(rec.history.text).toEqual(["L1", "L2", "L3", "L4", "L5", "L6"]);
    expect(rec.history.rows.map((row) => row.rowId)).toEqual([0, 1, 2, 3, 4, 5]);
    expect(rec.source.historyStatus.degraded).toBe(false);
  });

  test("column reflow preserves archived geometry and an exact live boundary", async () => {
    const rec = recorder(20, 4);
    await feed(rec, "abcdefghijklmnopqrstuvwxyz0123456789\r\nB\r\nC\r\nD");
    const archived = structuredClone(rec.history.rows[0]);
    expect(rec.history.text).toEqual(["abcdefghijklmnopqrst"]);
    rec.source.resize(10, 4);
    await rec.source.settle();
    expect(rec.history.text).toEqual(["abcdefghijklmnopqrst", "uvwxyz0123"]);
    expect(rec.history.rows[0]).toEqual(archived);
    expect(rec.history.rows.at(-1)!.cols).toBe(10);
    expect(rec.source.visibleLines()).toEqual(["456789", "B", "C", "D"]);
    rec.source.resize(40, 4);
    await rec.source.settle();
    expect(rec.history.text).toEqual(["abcdefghijklmnopqrst", "uvwxyz0123"]);
    expect(rec.source.visibleLines()).toEqual(["456789", "B", "C", "D"]);
    expect(rec.source.historyStatus).toMatchObject({ degraded: false, rewraps: 0, gaps: 0 });
  });

  test("the alternate buffer archives nothing by any path", async () => {
    const rec = await filled();
    await feed(rec, "\x1b[?1049h");
    await feed(rec, "A\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH\x1b[2J\x1b[?2J\x1b[1;1H\x1b[3M\x1b[2S\x1b[2L\x1bM\x1b#8");
    expect(rec.history.rows).toEqual([]);
    expect(rec.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 0 });

    await feed(rec, "\x1b[?1049l");
    expect(rec.source.visibleLines()).toEqual(["L1", "L2", "L3", "L4", "L5", "L6"]);
    expect(rec.history.rows).toEqual([]);
  });

  test("a scroll inside a region below the top margin counts the row it destroys", async () => {
    const rec = await filled();
    await feed(rec, "\x1b[2;4r\x1b[4;1H\n");
    expect(rec.source.visibleLines()).toEqual(["L1", "L3", "L4", "", "L5", "L6"]);
    expect(rec.history.rows).toEqual([]);
    expect(rec.source.historyStatus).toEqual({ degraded: false, gaps: 0, rewraps: 0, discarded: 1 });

    // The same grid mutation, the same row destroyed, driven by `CSI S` instead:
    // the two must not disagree about what was lost.
    const viaScrollUp = await filled();
    await feed(viaScrollUp, "\x1b[2;4r\x1b[S");
    expect(viaScrollUp.source.visibleLines()).toEqual(rec.source.visibleLines());
    expect(viaScrollUp.source.historyStatus).toEqual(rec.source.historyStatus);
  });

  test("a sink that throws from every method leaves the parser running", async () => {
    // `guard` reports a failed row as a gap, so a sink whose gap() throws too
    // makes the safety net itself the escape route.
    const term = bare();
    new XtermFrameAdapter(term).onArchiveRow({
      row: () => { throw new Error("sink row"); },
      gap: () => { throw new Error("sink gap"); },
      discarded: () => { throw new Error("sink discarded"); },
    });
    expect(await parses(term, "a\r\nb\r\nc\r\nd\r\ne\r\nf")).toBe(true);
    expect(await parses(term, "\x1b[2S\x1b[2J")).toBe(true);
  });

  test("a second archive sink over one terminal is refused at install", async () => {
    const term = bare();
    const first = new XtermFrameAdapter(term);
    const second = new XtermFrameAdapter(term);
    const firstSink = counting();
    const detachFirst = first.onArchiveRow(firstSink);
    // A second patch would capture the first's replacement as its own original,
    // so the first detach could restore nothing and the last one would reinstate
    // a detached adapter's hook for the life of the terminal.
    expect(() => second.onArchiveRow(counting())).toThrow(/already/i);

    detachFirst();
    const secondSink = counting();
    second.onArchiveRow(secondSink)();
    await parses(term, "1\r\n2\r\n3\r\n4\r\n5\r\n6");
    expect([firstSink.rows, secondSink.rows]).toEqual([0, 0]);
  });

  for (const [label, sequence] of [["ED(3)", "\x1b[3J"], ["RIS", "\x1bc"]] as const) {
    test(`a history that fails its clear does not take the parser with it: ${label}`, async () => {
      // A store whose disk has gone reports the failure through the callback its
      // owner supplied, and that runs from inside this parser handler.
      const rec = await filled();
      rec.history.clear = () => { throw new Error("history unavailable"); };
      rec.source.feed(sequence);
      const settled = await Promise.race([
        rec.source.settle().then(() => true),
        new Promise<boolean>((resolve) => setTimeout(() => resolve(false), 250)),
      ]);
      expect(settled).toBe(true);
      await feed(rec, "X1\r\nX2");
      expect(rec.source.revision).toBe(3);
    });
  }

  test("archived rows carry SGR and OSC 8 metadata in their spans", async () => {
    const rec = recorder(20, 4);
    await feed(rec,
      "\x1b[1;31mred\x1b[0m \x1b]8;;https://ex.example/a\x1b\\link\x1b]8;;\x1b\\" +
      "\r\nB\r\nC\r\nD\r\nE");
    expect(rec.history.rows).toHaveLength(1);
    expect(rec.history.rows[0]).toMatchObject({ cols: 20, wrapped: false, rowId: 0 });
    const spans = rec.history.rows[0].spans;
    expect(spans[0]).toEqual({ text: "red", cells: 3, sgr: "\x1b[0;1;38;5;1m" });
    // xterm 6 marks the cells of an OSC 8 span underlined in the cell attributes
    // themselves, with no explicit style — so a faithful record of those cells
    // carries the underline the guest never wrote.
    expect(spans.find((span) => span.uri)).toEqual({
      text: "link", cells: 4, sgr: "\x1b[0;4:1m", uri: "https://ex.example/a",
    });
  });
});
