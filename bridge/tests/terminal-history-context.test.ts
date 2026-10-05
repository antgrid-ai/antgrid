import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalManager, closeTerminalHistoryStore } from "../src/terminal-manager";
import { TerminalHistoryStore } from "../src/terminal-frames/history";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { type TerminalHistoryRow } from "../src/terminal-frames/protocol";
import { createConnState } from "../src/conn-state";

const SMALL_ROWS = 6;
const CONPTY_STARTUP_MS = 300;
const PLAIN = "\x1b[0m";

const textOf = (row: { spans: Array<{ text: string }> }) => row.spans.map((s) => s.text).join("").trimEnd();

let root: string;
let previousAbDir: string | undefined;

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-history-context-"));
  process.env.ANTGRID_DIR = root;
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
});

afterEach(() => {
  closeTerminalHistoryStore();
  delete process.env.ANTGRID_TERMINAL_HISTORY_TEST;
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  rmSync(root, { recursive: true, force: true });
});

describe("TerminalRunHistory.neighbours", () => {
  function archive(count: number): { store: TerminalHistoryStore; runId: string; epoch: number } {
    const store = new TerminalHistoryStore(join(root, "neighbours.sqlite"));
    const runId = crypto.randomUUID();
    const run = store.openRun(runId);
    for (let i = 0; i < count; i++) {
      run.append({ cols: 20, wrapped: false, spans: [{ text: `row${i}`, cells: 20, sgr: PLAIN }] });
    }
    run.flush();
    return { store, runId, epoch: run.page(0, 0).history.epoch };
  }

  test("returns the rows beside a range, oldest first, and says whether the archive ends there", () => {
    const { store, runId, epoch } = archive(30);
    try {
      const run = store.openRun(runId);

      const middle = run.neighbours(epoch, 10, 15, 3);
      const end = run.neighbours(epoch, 25, 30, 8);

      expect(middle.before.map((r: TerminalHistoryRow) => r.rowId)).toEqual([7, 8, 9]);
      expect(middle.after.map((r: TerminalHistoryRow) => r.rowId)).toEqual([15, 16, 17]);
      expect(middle.reachedEnd).toBe(false);
      expect(end.after.map((r: TerminalHistoryRow) => r.rowId)).toEqual([]);
      expect(end.reachedEnd).toBe(true);
    } finally {
      store.close();
    }
  });

  test("sees rows still waiting to be flushed, and never throws once retired", () => {
    const store = new TerminalHistoryStore(join(root, "unflushed.sqlite"));
    try {
      const run = store.openRun(crypto.randomUUID());
      run.append({ cols: 20, wrapped: false, spans: [{ text: "a", cells: 20, sgr: PLAIN }] });
      run.append({ cols: 20, wrapped: false, spans: [{ text: "b", cells: 20, sgr: PLAIN }] });
      const epoch = run.page(0, 0).history.epoch;

      expect(run.neighbours(epoch, 0, 1, 4).after.map(textOf)).toEqual(["b"]);

      run.retire();
      expect(run.neighbours(epoch, 0, 1, 4)).toEqual({ before: [], after: [], reachedEnd: false });
    } finally {
      store.close();
    }
  });
});

describe("TerminalManager.historyContext", () => {
  function spawn(manager: TerminalManager): void {
    manager.spawn({
      terminalId: "t1",
      rows: SMALL_ROWS,
      retainScrollbackOnExit: false,
      command: process.execPath,
      args: ["-e", "setTimeout(() => {}, 120000);"],
    });
  }

  async function emit(manager: TerminalManager, data: string): Promise<void> {
    const screens = (manager as unknown as { screens: Map<string, TerminalFrameSource> }).screens;
    const screen = screens.get("t1")!;
    screen.feed(data);
    await screen.settle();
  }

  async function booted(): Promise<{ manager: TerminalManager; runId: string; epoch: number; newest: ReturnType<TerminalManager["historyPage"]> }> {
    const manager = new TerminalManager(() => {}, undefined, createConnState());
    spawn(manager);
    await new Promise((resolve) => setTimeout(resolve, CONPTY_STARTUP_MS));
    await emit(manager, Array.from({ length: 120 }, (_, i) => `ctx${i}\r\n`).join(""));
    const runId = manager.runId("t1")!;
    const boundary = manager.historyPage(runId, 0, 0)!.history;
    return { manager, runId, epoch: boundary.epoch, newest: manager.historyPage(runId, boundary.epoch, boundary.nextRowId) };
  }

  test("continues the newest page with the live screen, and says that is the end", async () => {
    const { manager, runId, newest } = await booted();
    try {
      const page = newest!;
      const lastArchived = Number(textOf(page.rows[page.rows.length - 1]!).slice("ctx".length));

      const context = manager.historyContext(runId, page, "t1")!;

      expect(context.afterComplete).toBe(true);
      expect(context.after).toHaveLength(SMALL_ROWS);
      expect(textOf(context.after[0]!)).toBe(`ctx${lastArchived + 1}`);
      expect(context.after.map(textOf)).toContain("ctx119");
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("never calls the end of a dead run's archive the end of its output", async () => {
    const { manager, runId, newest } = await booted();
    try {
      const context = manager.historyContext(runId, newest!, undefined)!;

      expect(context.after).toEqual([]);
      expect(context.afterComplete).toBe(false);
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("takes an older page's continuation from the archive, not the screen", async () => {
    const { manager, runId, newest } = await booted();
    try {
      const page = { ...newest!, rows: newest!.rows.slice(60, 65) };

      const context = manager.historyContext(runId, page, "t1")!;

      expect(context.afterComplete).toBe(false);
      expect(context.after[0]!.spans[0]!.text.trimEnd()).toBe(textOf(newest!.rows[65]!));
      expect(context.after.map(textOf)).not.toContain("ctx119");
      expect(context.before).toHaveLength(48);
      expect(textOf(context.before[47]!)).toBe(textOf(newest!.rows[59]!));
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("answers nothing for a page with no rows or a run the archive does not hold", async () => {
    const { manager, runId, newest } = await booted();
    try {
      expect(manager.historyContext(runId, { ...newest!, rows: [] }, "t1")).toBeUndefined();
      expect(manager.historyContext(crypto.randomUUID(), newest!, "t1")).toBeUndefined();
    } finally {
      manager.killAll();
    }
  }, 30000);
});
