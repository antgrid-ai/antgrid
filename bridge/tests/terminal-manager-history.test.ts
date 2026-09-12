import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { TerminalManager, closeTerminalHistoryStore } from "../src/terminal-manager";
import { TerminalHistoryStore } from "../src/terminal-frames/history";
import { resolveTerminalHistoryPath } from "../src/antgrid-dir";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { ScrollbackBuffer } from "../src/scrollback";
import { createConnState } from "../src/conn-state";

// Small enough that 40 lines definitely scroll several off the top — history
// only records rows that actually LEAVE the viewport (see xterm-adapter.ts).
const SMALL_ROWS = 6;

/** Idles until the test decides the run ends. Output is written by `emit`
 *  rather than printed by the guest, so a test never waits on a PTY. */
const IDLE = "setTimeout(() => {}, 120000);";

/** Prints before it idles, for the one test that asserts the REAL PTY output
 *  path reaches the archive. */
const PRINTER = "for (let i = 0; i < 40; i++) process.stdout.write(`scrollline${i}\r\n`);" + IDLE;

function spawnPty(manager: TerminalManager, opts: { retain?: boolean; program?: string } = {}): void {
  manager.spawn({
    terminalId: "t1",
    rows: SMALL_ROWS,
    retainScrollbackOnExit: opts.retain ?? false,
    command: process.execPath,
    args: ["-e", opts.program ?? IDLE],
  });
}

/** The exact bytes `clear` and ncurses' E3 capability send — CSI H, CSI 2J,
 *  CSI 3J — which is what drives `TerminalRunHistory.clear()`. */
const CLEAR_BYTES = "\x1b[H\x1b[2J\x1b[3J";

/** Writes `data` into the terminal's screen and raw scrollback in the order the
 *  output handler writes a PTY chunk — source first, then scrollback.
 *  Resolves once the parser has consumed it, which is also
 *  when the rows it produced are committed: `TerminalFrameSource` flushes the
 *  history handle from every parsed-write callback, and `settle()` queues
 *  behind that write. So a read taken after this call needs no poll. */
async function emit(manager: TerminalManager, data: string): Promise<void> {
  const screens = (manager as unknown as { screens: Map<string, TerminalFrameSource> }).screens;
  const scrollbacks = (manager as unknown as { scrollbacks: Map<string, ScrollbackBuffer> }).scrollbacks;
  const screen = screens.get("t1")!;
  screen.feed(data);
  scrollbacks.get("t1")!.append(data);
  await screen.settle();
}

const lines = (count: number, prefix: string) =>
  Array.from({ length: count }, (_, index) => `${prefix}${index}\r\n`).join("");

/** ConPTY repaints when it starts, which is output this file does not control
 *  and must not count. Every test lets that land before it writes anything of
 *  its own; a silent guest emits nothing afterwards. */
const CONPTY_STARTUP_MS = 300;

async function waitFor<T>(probe: () => T | undefined, timeoutMs: number): Promise<T | undefined> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = probe();
    if (value !== undefined) return value;
    if (Date.now() >= deadline) return undefined;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
}

let root: string;
let previousAbDir: string | undefined;
let openedReaders: TerminalHistoryStore[];

beforeEach(() => {
  previousAbDir = process.env.ANTGRID_DIR;
  root = mkdtempSync(join(tmpdir(), "antgrid-tm-history-"));
  process.env.ANTGRID_DIR = root;
  process.env.ANTGRID_TERMINAL_HISTORY_TEST = "1";
  openedReaders = [];
});

afterEach(() => {
  // Closed before removing `root`: on Windows an sqlite handle still open
  // over a file inside the directory `rmSync` is about to delete throws
  // EBUSY. `closeTerminalHistoryStore` covers the manager's own connection;
  // `openedReaders` covers every read-side connection a test opened itself.
  for (const reader of openedReaders) reader.close();
  closeTerminalHistoryStore();
  delete process.env.ANTGRID_TERMINAL_HISTORY_TEST;
  if (previousAbDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = previousAbDir;
  rmSync(root, { recursive: true, force: true });
});

function makeManager() {
  return new TerminalManager(() => {}, undefined, createConnState());
}

/** A second connection onto the same store the manager under test is
 *  writing through — WAL mode supports concurrent readers by design. Tracked
 *  so `afterEach` can close it before the temp dir is removed. */
function openReader(): TerminalHistoryStore {
  const reader = new TerminalHistoryStore(resolveTerminalHistoryPath());
  openedReaders.push(reader);
  return reader;
}


describe("terminal history lifecycle", () => {
  test("real PTY output is archived under the run id", async () => {
    const manager = makeManager();
    try {
      spawnPty(manager, { program: PRINTER });
      const reader = openReader();
      const runId = manager.runId("t1")!;
      const count = await waitFor(() => {
        const record = reader.record(runId);
        return record && record.nextRowId > 0 ? record.nextRowId : undefined;
      }, 15000);
      expect(count).toBeGreaterThan(0);
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("ordinary exit retains durable rows until explicit forget", async () => {
    const manager = makeManager();
    try {
      spawnPty(manager);
      const reader = openReader();
      await new Promise((resolve) => setTimeout(resolve, CONPTY_STARTUP_MS));
      const runId = manager.runId("t1")!;
      await emit(manager, lines(40, "before-exit"));
      const count = reader.record(runId)!.nextRowId;
      manager.kill("t1");
      expect(await waitFor(() => manager.has("t1") ? undefined : true, 10000)).toBe(true);
      expect(reader.record(runId)!.nextRowId).toBeGreaterThanOrEqual(count);
      manager.forget("t1");
      expect(reader.record(runId)).toBeNull();
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("same-id respawn retains both runs until the terminal is forgotten", async () => {
    const manager = makeManager();
    try {
      spawnPty(manager, { retain: true });
      const reader = openReader();
      await new Promise((resolve) => setTimeout(resolve, CONPTY_STARTUP_MS));
      const first = manager.runId("t1")!;
      await emit(manager, lines(40, "first-run"));
      const count = reader.record(first)!.nextRowId;
      spawnPty(manager);
      const second = manager.runId("t1")!;
      expect(second).not.toBe(first);
      expect(reader.record(first)!.nextRowId).toBeGreaterThanOrEqual(count);
      expect(reader.record(second)).not.toBeNull();
      manager.forget("t1");
      expect(reader.record(first)).toBeNull();
      expect(reader.record(second)).toBeNull();
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("opening the manager store preserves committed rows from a previous process", () => {
    const previous = new TerminalHistoryStore(resolveTerminalHistoryPath());
    const runId = crypto.randomUUID();
    const run = previous.openRun(runId);
    run.append({ cols: 80, wrapped: false, spans: [{ text: "retained", cells: 8, sgr: "\x1b[0m" }] });
    run.flush();
    previous.close();
    const manager = makeManager();
    try {
      spawnPty(manager);
      const reader = openReader();
      expect(reader.record(runId)!.nextRowId).toBe(1);
      const page = reader.openRun(runId).page(0, 1);
      expect(page.rows[0]?.spans[0]?.text).toBe("retained");
    } finally {
      manager.killAll();
    }
  });

  test("opening beside a live history reader does not recreate the database", () => {
    const reader = openReader();
    const runId = crypto.randomUUID();
    const run = reader.openRun(runId);
    run.append({ cols: 80, wrapped: false, spans: [{ text: "keep", cells: 4, sgr: "\x1b[0m" }] });
    run.flush();
    const manager = makeManager();
    try {
      spawnPty(manager);
      expect(reader.record(runId)!.nextRowId).toBe(1);
      expect(openReader().record(runId)!.nextRowId).toBe(1);
    } finally {
      manager.killAll();
    }
  });

  test("parser failure preserves committed history and never reseeds from a raw tail", async () => {
    const manager = makeManager();
    try {
      spawnPty(manager);
      const reader = openReader();
      await new Promise((resolve) => setTimeout(resolve, CONPTY_STARTUP_MS));
      const runId = manager.runId("t1")!;
      await emit(manager, lines(40, "committed"));
      const count = reader.record(runId)!.nextRowId;
      const screen = (manager as unknown as { screens: Map<string, TerminalFrameSource> }).screens.get("t1")!;
      screen.feed("x".repeat(1_000_001));
      expect(() => screen.capture(performance.now())).toThrow("backlog");
      expect(() => screen.capture(performance.now())).toThrow("backlog");
      expect(reader.record(runId)!.nextRowId).toBe(count);
      expect(screen.failure).toBeDefined();
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("explicit scrollback clear starts a new history epoch", async () => {
    const manager = makeManager();
    try {
      spawnPty(manager);
      const reader = openReader();
      await new Promise((resolve) => setTimeout(resolve, CONPTY_STARTUP_MS));
      const runId = manager.runId("t1")!;
      await emit(manager, lines(40, "before-clear"));
      const epoch = reader.record(runId)!.epoch;
      await emit(manager, CLEAR_BYTES + lines(40, "after-clear"));
      const record = reader.record(runId)!;
      expect(record.epoch).toBe(epoch + 1);
      const page = reader.openRun(runId).page(record.epoch, record.nextRowId);
      expect(page.rows.every((row) => !row.spans.some((span) => span.text.includes("before-clear")))).toBe(true);
    } finally {
      manager.killAll();
    }
  }, 30000);

  test("unavailable history storage does not prevent a live terminal", () => {
    mkdirSync(resolveTerminalHistoryPath(), { recursive: true });
    const manager = makeManager();
    try {
      expect(() => spawnPty(manager)).not.toThrow();
      expect(manager.has("t1")).toBe(true);
    } finally {
      manager.killAll();
    }
  });
});
