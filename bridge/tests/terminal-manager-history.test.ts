// D3: the real run lifecycle for the terminal history store — open at spawn,
// reattach (guarded) across a rebuild, retire at dispose, delete on forget or
// a non-retained exit, sweep at the next store open. terminal-frame-promotion
// already covers the rebuild/rebuild-budget machinery itself; this file only
// adds the history dimension on top of it.
//
// ANTGRID_DIR is set explicitly, unlike every other terminal-manager test
// file, and ANTGRID_TERMINAL_HISTORY_TEST opts in on top of it:
// `terminalHistoryStore()` (terminal-manager.ts) refuses to touch disk under
// a bare `bun test` run, and refuses even under an overridden ANTGRID_DIR
// unless a test explicitly asks for the real store — see its own doc for why
// piggybacking on ANTGRID_DIR alone is not safe. This file is exactly the one
// that opts in, and it takes on the matching duty of closing the store (see
// afterEach) before its own temp dir cleanup, which a leaked handle would
// otherwise fail on Windows (EBUSY).
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
import { __setRootForTest } from "../src/logger";

const isWin = process.platform === "win32";
// Small enough that 40 lines definitely scroll several off the top — history
// only records rows that actually LEAVE the viewport (see xterm-adapter.ts).
const SMALL_ROWS = 6;
const LOOP_COMMAND = isWin
  ? "for /L %i in (1,1,40) do @echo scrollline%i\r"
  : "for i in $(seq 1 40); do echo scrollline$i; done\n";

// The two clear-guard tests below need a shell that reliably echoes the raw
// bytes it is typed, one keystroke write at a time — an ambient `$SHELL`
// pointed at an interactive git-bash (common on a dev machine, irrelevant to
// what these tests exercise) redraws its bracketed-paste prompt mid-command
// and garbles a multi-character write, so they pin an explicit shell rather
// than relying on `resolveShell()`'s default. `printf`'s `\NNN` octal escape
// is what emits the exact bytes `clear`/ncurses E3 sends (CSI H, CSI 2J,
// CSI 3J) without depending on this shell's terminfo including CSI 3J for
// its own `clear` builtin.
const CLEAR_SHELL = isWin ? "powershell.exe" : "/bin/bash";
const CLEAR_LOOP_COMMAND = isWin
  ? "1..40 | ForEach-Object { Write-Host \"scrollline$_\" }\r"
  : "for i in $(seq 1 40); do echo scrollline$i; done\n";
const CLEAR_COMMAND = isWin
  ? "Write-Host -NoNewline ([char]27+'[H'+[char]27+'[2J'+[char]27+'[3J')\r"
  : "printf '\\033[H\\033[2J\\033[3J'\n";

async function waitFor<T>(probe: () => T | undefined, timeoutMs: number): Promise<T | undefined> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const value = probe();
    if (value !== undefined) return value;
    if (Date.now() >= deadline) return undefined;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
}

/** Forces `ensureLiveScreen` to treat `screen` as latched, exactly as
 *  `terminal-frame-promotion.test.ts` does, without a real parser overflow. */
function forceFailure(screen: unknown, message = "simulated parser overflow"): void {
  Object.defineProperty(screen, "failure", { configurable: true, get: () => new Error(message) });
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

/** Capture pino JSONL lines written during `fn` — the same technique as
 *  paired-phones.test.ts, needed because a component child logger's calls
 *  are invisible to a plain "spy the warn method" approach. */
function captureLogLines(fn: () => void): string[] {
  const lines: string[] = [];
  __setRootForTest({
    write(s: string): boolean {
      lines.push(s);
      return true;
    },
  }, "debug");
  try {
    fn();
  } finally {
    __setRootForTest(process.stdout);
  }
  return lines;
}

describe("terminal history lifecycle (D3)", () => {
  test("output that scrolls off is archived under the terminal's run id", async () => {
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS });
    await new Promise((r) => setTimeout(r, 300));
    // Opened only after the manager's own spawn has already claimed the
    // store: the manager's lazy open sweeps-by-recreating the file (see
    // openHistoryStore's doc), and racing that against an already-open
    // second connection is a Windows-specific EBUSY hazard worth avoiding
    // rather than relying on the delete's own best-effort try/catch.
    const reader = openReader();
    manager.write("t1", LOOP_COMMAND);

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();
    const nextRowId = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.nextRowId > 0 ? record.nextRowId : undefined;
    }, 5000);
    expect(nextRowId).toBeGreaterThan(0);

    manager.killAll();
  });

  test("a non-retained exit deletes the run's rows", async () => {
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS });
    await new Promise((r) => setTimeout(r, 300));
    const reader = openReader();
    manager.write("t1", LOOP_COMMAND);

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();
    await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.nextRowId > 0 ? true : undefined;
    }, 5000);

    manager.kill("t1");
    expect(await waitFor(() => (manager.has("t1") ? undefined : true), 5000)).toBe(true);
    expect(await waitFor(() => (reader.record(runId!) === null ? true : undefined), 2000)).toBe(true);
  });

  test("retainScrollbackOnExit keeps the run's rows past exit; forget() then deletes them", async () => {
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS, retainScrollbackOnExit: true });
    await new Promise((r) => setTimeout(r, 300));
    const reader = openReader();
    manager.write("t1", LOOP_COMMAND);

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();
    const rowsBeforeExit = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.nextRowId > 0 ? record.nextRowId : undefined;
    }, 5000);
    expect(rowsBeforeExit).toBeGreaterThan(0);

    manager.kill("t1");
    expect(await waitFor(() => (manager.has("t1") ? undefined : true), 5000)).toBe(true);
    // Retained: the exit alone must not have deleted anything. `rowsBeforeExit`
    // is sampled at the FIRST archived row while the 40-line loop is still
    // running, so more rows can land before `kill` above — under load, more
    // than one does. The assertion's intent is "the retained exit deleted
    // nothing", not "nextRowId froze the instant we sampled it".
    expect(manager.runId("t1")).toBe(runId);
    const recordAfterExit = reader.record(runId!);
    expect(recordAfterExit).not.toBeNull();
    expect(recordAfterExit!.nextRowId).toBeGreaterThanOrEqual(rowsBeforeExit!);

    manager.forget("t1");
    expect(reader.record(runId!)).toBeNull();
  });

  test("a same-id respawn deletes the previous run's rows and opens a fresh run", async () => {
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS, retainScrollbackOnExit: true });
    await new Promise((r) => setTimeout(r, 300));
    const reader = openReader();
    manager.write("t1", LOOP_COMMAND);

    const runId1 = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId1).toBeDefined();
    await waitFor(() => {
      const record = reader.record(runId1!);
      return record && record.nextRowId > 0 ? true : undefined;
    }, 5000);

    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS });
    await new Promise((r) => setTimeout(r, 200));
    const runId2 = manager.runId("t1");
    expect(runId2).toBeDefined();
    expect(runId2).not.toBe(runId1);
    expect(reader.record(runId1!)).toBeNull();

    manager.killAll();
  });

  test("a rebuild's reseed does not duplicate rows already archived by the failed source", async () => {
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS });
    await new Promise((r) => setTimeout(r, 300));
    const reader = openReader();
    manager.write("t1", LOOP_COMMAND);

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();
    const rowsBeforeRebuild = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.nextRowId > 0 ? record.nextRowId : undefined;
    }, 5000);
    expect(rowsBeforeRebuild).toBeGreaterThan(0);

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    const before = screens.get("t1");
    expect(before).toBeInstanceOf(TerminalFrameSource);
    forceFailure(before);

    // getAttachSnapshot drives the exact rebuild+reseed path `ensureLiveScreen`
    // implements — see terminal-manager.ts.
    const snap = await manager.getAttachSnapshot("t1");
    expect(snap).not.toBeNull();
    const after = screens.get("t1");
    expect(after).not.toBe(before);
    expect(manager.runId("t1")).toBe(runId); // same run, reattached

    // Without ReplayGuardedHistory this would have roughly DOUBLED: the
    // reseed replays the same rows the failed source already archived.
    const rowsAfterRebuild = reader.record(runId!)!.nextRowId;
    expect(rowsAfterRebuild).toBe(rowsBeforeRebuild!);

    // The guard lifts once the reseed settles: genuinely new output after the
    // rebuild must still be archived, not silently suppressed forever.
    manager.write("t1", LOOP_COMMAND);
    const rowsAfterFreshOutput = await waitFor(() => {
      const n = reader.record(runId!)!.nextRowId;
      return n > rowsAfterRebuild ? n : undefined;
    }, 5000);
    expect(rowsAfterFreshOutput).toBeGreaterThan(rowsAfterRebuild);

    manager.killAll();
  });

  test("a fresh store open sweeps rows no live terminal on this process can ever claim again", async () => {
    // Simulates a crash: rows committed under a run id with nothing in ANY
    // process's in-memory `runIds` map pointing at it (that map never
    // survives a restart — see openHistoryStore's doc in terminal-manager.ts).
    const path = resolveTerminalHistoryPath();
    const orphan = new TerminalHistoryStore(path);
    const runId = crypto.randomUUID();
    const handle = orphan.openRun(runId);
    handle.append({ cols: 80, wrapped: false, spans: [{ text: "orphan", cells: 6, sgr: "\x1b[0m" }] });
    handle.flush();
    expect(orphan.record(runId)!.nextRowId).toBe(1);
    orphan.close();

    // The manager's lazy store is a fresh open here (nothing in this test
    // opened it yet), which is exactly the "next boot" this sweep protects.
    // No reader is opened until after this spawn — see the note in the first
    // test above for why racing it against the sweep's own delete is unsafe.
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS });
    await new Promise((r) => setTimeout(r, 300));

    const reader = openReader();
    expect(reader.record(runId)).toBeNull();

    manager.killAll();
  });

  test("a guarded rebuild does not re-apply a clear already recorded, and still archives content made after it", async () => {
    // Explicit budget: this test chains three separate `waitFor(..., 5000)`
    // polls (rows scrolling, the clear landing, rows scrolling again), well
    // past bun:test's 5000ms default per-test timeout on a loaded box.
    // Reproduces the trap `ReplayGuardedHistory` exists to guard against: the
    // reseed replays up to 10,000 raw chars of scrollback, and a CSI 3J
    // sitting in that tail (any `clear` this run issued recently) must not
    // fire `history.clear()` a SECOND time — that DELETEs every row for the
    // run regardless of epoch, so a naive pass-through wipes everything
    // recorded since the real clear, not just what the clear itself covered.
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS, command: CLEAR_SHELL });
    await new Promise((r) => setTimeout(r, 500));
    const reader = openReader();

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();

    manager.write("t1", CLEAR_LOOP_COMMAND);
    await waitFor(() => (reader.record(runId!)!.nextRowId > 0 ? true : undefined), 5000);
    // The loop above keeps emitting for a little while after `nextRowId`
    // first ticks past zero — let it fully settle before typing the next
    // command, or the CLEAR bytes below land mid-loop-output instead of at
    // a fresh prompt.
    await new Promise((r) => setTimeout(r, 500));

    manager.write("t1", CLEAR_COMMAND);
    const afterClear = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.epoch > 0 ? record : undefined;
    }, 8000);
    expect(afterClear).toBeDefined();
    expect(afterClear!.epoch).toBe(1);

    // Real output recorded AFTER the clear, under the new epoch — this is
    // exactly what a double-applied clear would destroy.
    manager.write("t1", CLEAR_LOOP_COMMAND);
    const beforeRebuild = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.epoch === 1 && record.nextRowId > 0 ? record : undefined;
    }, 5000);
    expect(beforeRebuild).toBeDefined();

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    forceFailure(screens.get("t1"));
    const snap = await manager.getAttachSnapshot("t1");
    expect(snap).not.toBeNull();
    await new Promise((r) => setTimeout(r, 300));

    const afterRebuild = reader.record(runId!);
    expect(afterRebuild).not.toBeNull();
    // The epoch the real clear minted must survive the rebuild untouched — a
    // replayed clear re-firing would bump it a second time (to 2).
    expect(afterRebuild!.epoch).toBe(1);
    // And every row recorded under it (the post-clear loop) must still be
    // there — a replayed clear re-firing deletes them along with the epoch.
    expect(afterRebuild!.nextRowId).toBeGreaterThanOrEqual(beforeRebuild!.nextRowId);
    const page = reader.openRun(runId!).page(1, afterRebuild!.nextRowId);
    expect(page.expired).toBe(false);
    expect(page.rows.length).toBeGreaterThan(0);

    manager.killAll();
  }, 20000);

  test("a guarded rebuild archives content the failed source had not archived yet, instead of dropping it", async () => {
    // The failed source's un-scrolled viewport content (never archived,
    // because it had not left the screen yet) is exactly what an
    // unconditional append suppression would lose for good: the guard must
    // stop suppressing once it has consumed as many duplicate appends as the
    // real handle already recorded, not for the whole reseed regardless.
    //
    // A short burst archives (and settles) too fast for a 30ms poll to ever
    // observe it mid-flight — by the time `nextRowId` is first seen above 0
    // it is already at its final value, with nothing left un-scrolled for the
    // rebuild to recover (this is what made earlier versions of this test
    // flap or pass for the wrong reason). A long-running burst gives room to
    // catch it mid-flight, and Ctrl+C right after that abandons the loop for
    // good — settling BEFORE the failure is forced means the underlying PTY
    // produces no more genuinely new bytes afterward, so any archived-row
    // growth post-rebuild can only come from the reseed's replay of the raw
    // scrollback recovering content the original screen's live viewport had
    // not scrolled off yet, never from ordinary live output racing the test.
    // The reseed replays those same raw bytes into a BLANK replacement
    // screen, which starts scrolling from row zero instead of wherever the
    // live screen happened to be, so that trailing content scrolls past the
    // viewport during replay and must come out archived — a guard that
    // suppresses unconditionally for the whole reseed (the pre-fix
    // behaviour) would lose it instead, capping the run at whatever
    // `rowsBeforeRebuild` already was no matter how much more the replay
    // derives.
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS, command: CLEAR_SHELL });
    await new Promise((r) => setTimeout(r, 500));
    const reader = openReader();

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();

    const LONG_BURST = isWin
      ? "1..4000 | ForEach-Object { Write-Host \"scrollline$_\" }\r"
      : "for i in $(seq 1 4000); do echo scrollline$i; done\n";
    manager.write("t1", LONG_BURST);
    const rowsBeforeRebuild = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.nextRowId > 0 ? record.nextRowId : undefined;
    }, 5000);
    expect(rowsBeforeRebuild).toBeGreaterThan(0);
    // Well short of the burst's eventual total (~3994 archived rows once it
    // fully drains) — proves the failure landed mid-burst, not after it, so
    // there is real backlog left for the replay to recover.
    expect(rowsBeforeRebuild!).toBeLessThan(3000);

    // Forced immediately (no settling wait) and read back immediately after:
    // the reseed's replay of the raw scrollback runs SYNCHRONOUSLY inside
    // `ensureLiveScreen` (`feed(seed)`, before the async `settle()` that lets
    // genuinely new PTY bytes start flowing again) — so any growth visible
    // right here is attributable to that replay recovering backlog, not to
    // the burst simply continuing to run after the rebuild.
    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    forceFailure(screens.get("t1"));
    const snap = await manager.getAttachSnapshot("t1");
    expect(snap).not.toBeNull();

    const rowsAfterRebuild = reader.record(runId!)!.nextRowId;
    expect(rowsAfterRebuild).toBeGreaterThan(rowsBeforeRebuild!);

    manager.killAll();
  }, 20000);
});

describe("terminal history store open failures (D3)", () => {
  test("a sweep failure other than ENOENT is logged, not silently swallowed", () => {
    const path = resolveTerminalHistoryPath();
    // A live connection already open at the exact path the D3 sweep is about
    // to try to remove — a stand-in for a stale holder (another process, a
    // leaked handle from a previous boot). WAL mode lets the manager's own
    // connection open successfully alongside it (openReader() below relies on
    // the same fact), so this only blocks the SWEEP's rmSync, not the store.
    const blocker = new TerminalHistoryStore(path);
    openedReaders.push(blocker); // afterEach closes it before rmSync(root)

    const lines = captureLogLines(() => {
      const manager = makeManager();
      // Triggers `terminalHistoryStore()`'s first (and, this test, only)
      // lazy open for this path, which runs the sweep this test is about.
      manager.spawn({ terminalId: "t1" });
      manager.killAll();
    });

    // The pre-fix bug: the sweep's catch had no discrimination at all — any
    // rmSync failure, ENOENT (expected) or not (this one), was swallowed in
    // total silence, so a sweep that removed nothing looked identical to a
    // fresh install with nothing to sweep in the first place.
    const warned = lines.some((line) => line.includes("Terminal history sweep could not remove"));
    expect(warned).toBe(true);
  });

  test("a store-open failure inside openHistoryRun does not crash spawn()", () => {
    const path = resolveTerminalHistoryPath();
    // The path itself exists as a DIRECTORY, not a file — `new Database(path)`
    // fails to open it (proven directly against bun:sqlite: "unable to open
    // database file"), a synchronous throw from deep inside
    // `terminalHistoryStore()` that has nothing to do with the sweep above.
    mkdirSync(path, { recursive: true });

    const manager = makeManager();
    // The pre-fix bug: `openHistoryRun` called `terminalHistoryStore()`
    // BEFORE its own try block, so this throw escaped uncaught out of
    // `spawn()` entirely — killing terminal spawning for the whole manager,
    // not just disabling history for this one run.
    expect(() => manager.spawn({ terminalId: "t1" })).not.toThrow();
    expect(manager.runId("t1")).toBeDefined(); // the PTY itself still started
    manager.killAll();
  });
});

describe("terminal history after a rebuild that cannot re-derive the archive (D3)", () => {
  test("a rebuild whose scrollback covers only part of the archive reports history as degraded", async () => {
    // The guard suppresses the first `nextRowId` appends of the reseed so a
    // replayed row can never be archived twice. When the replay derives FEWER
    // rows than that — the ordinary case on a long run, where 10,000 chars of
    // scrollback stand against a run that has printed far more — every one of
    // them is suppressed, including any the failed source never got to
    // archive (`fail()` throws away `unparsed`). Nothing can tell those apart
    // here, so the rebuild must report the uncertainty rather than hand the
    // app a fresh, clean `historyStatus` over a history with a hole in it.
    //
    // The scrollback is trimmed directly instead of by printing megabytes:
    // what makes the real case lossy is the ratio between the retained tail
    // and the archive, and a 200-char tail against ~30 archived rows is that
    // ratio, reached in a second rather than a minute.
    const manager = makeManager();
    // The pinned shell, as in the clear-guard tests above: the default
    // `resolveShell()` here is git-bash, which answers the cmd-style loop
    // with a couple of error lines rather than the 40 the ratio needs.
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS, command: CLEAR_SHELL });
    await new Promise((r) => setTimeout(r, 500));
    const reader = openReader();
    manager.write("t1", CLEAR_LOOP_COMMAND);

    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();
    const archived = await waitFor(() => {
      const record = reader.record(runId!);
      return record && record.nextRowId > 20 ? record.nextRowId : undefined;
    }, 8000);
    expect(archived).toBeGreaterThan(20);

    const scrollbacks = (manager as unknown as { scrollbacks: Map<string, ScrollbackBuffer> }).scrollbacks;
    const trimmed = new ScrollbackBuffer(200);
    trimmed.append(scrollbacks.get("t1")!.getContents());
    scrollbacks.set("t1", trimmed);

    const screens = (manager as unknown as { screens: Map<string, unknown> }).screens;
    forceFailure(screens.get("t1"));
    expect(await manager.getAttachSnapshot("t1")).not.toBeNull();

    const replacement = screens.get("t1") as TerminalFrameSource;
    expect(replacement).toBeInstanceOf(TerminalFrameSource);
    // `release()` (and so the gap) lands in the `settle()` continuation, one
    // microtask after the reseed the snapshot above already drove.
    const degraded = await waitFor(() => replacement.historyStatus.degraded || undefined, 2000);
    expect(degraded).toBe(true);
    expect(replacement.historyStatus.gaps).toBeGreaterThan(0);

    manager.killAll();
  }, 20000);

  test("a dispose landing after the store is closed does not re-open, and so does not re-sweep, the database", async () => {
    // `HostServer.shutdown` closes the store once every core has stopped, but
    // a PTY exit callback or a checkout teardown can still land after it
    // (killAllGracefully gives up at 5s). Opening the store SWEEPS it, so a
    // late dispose that lazily re-opened one would delete the file the
    // shutdown just checkpointed and leave a connection nothing ever closes.
    const manager = makeManager();
    manager.spawn({ terminalId: "t1", rows: SMALL_ROWS, retainScrollbackOnExit: true });
    await new Promise((r) => setTimeout(r, 300));
    manager.write("t1", LOOP_COMMAND);
    const runId = await waitFor(() => manager.runId("t1"), 2000);
    expect(runId).toBeDefined();

    // Short-lived readers throughout: a reader held OPEN across the late
    // dispose would itself block the errant sweep's rmSync on Windows and
    // hide the very thing this test is checking for.
    const readRun = () => {
      const reader = new TerminalHistoryStore(resolveTerminalHistoryPath());
      try { return reader.record(runId!)?.nextRowId; } finally { reader.close(); }
    };
    expect(await waitFor(() => { const n = readRun(); return n && n > 0 ? n : undefined; }, 5000)).toBeGreaterThan(0);

    closeTerminalHistoryStore();
    const before = readRun();

    manager.forget("t1"); // the late dispose
    expect(readRun()).toBe(before!);

    manager.killAll();
  }, 20000);
});
