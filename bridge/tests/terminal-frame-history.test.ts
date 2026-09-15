// D4/D5: the four plan gates that had no test at all, exercised directly
// against `TerminalHistoryStore`/`TerminalRunHistory` — no PTY, no
// `TerminalManager`. The run-lifecycle wiring (open/reattach/retire/delete,
// and the rebuild-reseed double-archive trap) is covered end-to-end in
// terminal-manager-history.test.ts; this file only proves the store's own
// contract: indexed paging, retention, crash durability, disk-full
// degradation, and the epoch/geometry invariants clear() and resize rely on.
//
// Every test opens its own store under its own temp directory and closes it
// (in a finally, so an assertion failure never leaves a handle open and
// turns a real failure into an unrelated EBUSY on the next test's rmSync) —
// never the real ~/.antgrid, and no ANTGRID_DIR override is needed since the
// path is passed directly to the constructor.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { TerminalHistoryStore, type TerminalRunHistory } from "../src/terminal-frames/history";
import { TerminalFrameSource } from "../src/terminal-frames/source";
import { TERMINAL_HISTORY_PAGE_ROWS, type TerminalHistoryRow } from "../src/terminal-frames/protocol";

let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "antgrid-history-"));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

/** A minimal, schema-valid row body (everything `TerminalRunHistory.append`
 *  needs besides the rowId it assigns). `cols` is left explicit at every call
 *  site in the resize test below — every other test just wants a valid row. */
function row(cols = 80, text = "line"): Omit<TerminalHistoryRow, "rowId"> {
  return { cols, wrapped: false, spans: [{ text, cells: text.length, sgr: "\x1b[0m" }] };
}

async function waitUntil(predicate: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    if (predicate()) return true;
    if (Date.now() >= deadline) return predicate();
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}

describe("D4: large-session pages read by index", () => {
  test("saved screens and archived run metadata share the retention budget", async () => {
    const store = new TerminalHistoryStore(join(root, "bounded.sqlite"), { runBytes: 1024, machineBytes: 2048 });
    const source = new TerminalFrameSource(80, 24);
    try {
      source.feed("x".repeat(1600));
      await source.settle();
      const frame = source.capture(0)!;
      for (let index = 0; index < 40; index++) {
        const runId = crypto.randomUUID();
        store.openRun(runId);
        store.bindRun(runId, "project", `terminal-${index}`);
        store.saveFinal(runId, frame);
        expect(store.record(runId)!.bytes).toBeLessThanOrEqual(1024);
        expect(store.latestFinal("project", `terminal-${index}`)?.frame).toBeUndefined();
        store.releaseRun(runId);
      }
      const db = (store as unknown as { db: Database }).db;
      const total = db.query<{ bytes: number }, []>("SELECT SUM(bytes) AS bytes FROM terminal_runs").get()!.bytes;
      expect(total).toBeLessThanOrEqual(2048);
      expect(store.latestFinal("project", "terminal-0")).toBeUndefined();
    } finally { source.dispose(); store.close(); }
  });
  test("page() answers a backward-paged walk in bounded memory and at a cost the archive's size does not move, with no repeated or skipped rowId", () => {
    const dbPath = join(root, "history.sqlite");
    const store = new TerminalHistoryStore(dbPath);
    let reader: TerminalHistoryStore | undefined;
    try {
      // Seeded via store.commit() directly, in large batches, rather than one
      // handle.append() per row — this is purely about getting a big enough
      // table fast; page()'s own read path (what this test actually proves) is
      // exercised entirely through the handles below.
      const seed = (runId: string, rows: number): void => {
        store.openRun(runId); // creates the terminal_runs row store.commit() needs
        const CHUNK = 5_000;
        for (let start = 0; start < rows; start += CHUNK) {
          const batch: TerminalHistoryRow[] = [];
          const size = Math.min(CHUNK, rows - start);
          for (let i = 0; i < size; i++) batch.push({ rowId: start + i, ...row(80, `scrollline${start + i}`) });
          store.commit(runId, 0, start + size, batch);
        }
      };
      const ROWS = 100_000;
      const CONTROL_ROWS = TERMINAL_HISTORY_PAGE_ROWS * 5;
      const runId = crypto.randomUUID();
      const controlRunId = crypto.randomUUID();
      seed(runId, ROWS);
      seed(controlRunId, CONTROL_ROWS);

      // A fresh connection, not `store.openRun(runId)` again: `openRun`
      // caches one handle per runId for the LIFE of the store, constructed
      // from whatever the DB held at first-open — reusing it here would read
      // back the stale (epoch 0, nextRowId 0) record from before any of the
      // bulk commits above, since those went through raw SQL and never
      // touched that cached handle's in-memory state. A second store on the
      // same file (WAL supports concurrent readers) is a real, fresh read.
      reader = new TerminalHistoryStore(dbPath);
      const handle = reader.openRun(runId);
      const control = reader.openRun(controlRunId);
      const total = handle.boundary().nextRowId;
      expect(total).toBe(ROWS);
      expect(control.boundary().nextRowId).toBe(CONTROL_ROWS);

      // The regression: the read query losing its index — rewrite its WHERE
      // clause as `rowId + 0 < ?` and SQLite can no longer seek on rowId, so
      // answering the OLDEST page means walking every newer row of the run
      // first. Paging to the top of a long session then degrades with the
      // session's length, which is the one thing this store exists to avoid.
      //
      // Stated as a ratio against the SAME read on a 1000-row archive, not as
      // a millisecond ceiling: this suite runs 289 files in parallel, and any
      // absolute bound tight enough to catch the scan is a coin flip on a
      // loaded box (a ceiling of 10ms was measured at 38ms in a full run).
      // The two sides are sampled alternately so a slow moment hits both, and
      // each keeps its MINIMUM — contention only ever adds time, so the floor
      // of many samples is the closest a shared machine gets to the real cost.
      const time = (fn: () => void): number => {
        const t0 = performance.now();
        fn();
        return performance.now() - t0;
      };
      const oldestPage = (h: TerminalRunHistory) => time(() => h.page(0, TERMINAL_HISTORY_PAGE_ROWS + 1));
      let bigFloorMs = Infinity;
      let controlFloorMs = Infinity;
      for (let sample = 0; sample < 20; sample++) {
        controlFloorMs = Math.min(controlFloorMs, oldestPage(control));
        bigFloorMs = Math.min(bigFloorMs, oldestPage(handle));
      }
      // Measured on this shape: 0.82-1.14x indexed (including four runs inside
      // a full parallel suite), 13-15x once the index is gone. The 100x row
      // count does not become a 100x ratio because both sides pay the same
      // fixed cost — one boundary() plus 200 JSON+Zod row parses — and on the
      // indexed side that constant IS the measurement. 4x sits between.
      expect(bigFloorMs).toBeLessThan(controlFloorMs * 4);

      // Bounded memory: reading one 200-row page must not pull the archive's
      // 100,000 rows into the heap. Not exact (GC timing is not ours to
      // control), so the bound is generous — well under the dataset's size.
      if (typeof globalThis.gc === "function") globalThis.gc();
      const before = process.memoryUsage().heapUsed;
      const midPage = handle.page(0, Math.floor(total / 2));
      if (typeof globalThis.gc === "function") globalThis.gc();
      const after = process.memoryUsage().heapUsed;
      expect(midPage.rows.length).toBeGreaterThan(0);
      expect(after - before).toBeLessThan(5 * 1024 * 1024);

      // Walk every page backwards from the end; the union must be exactly
      // every rowId once — no repeats, no gaps.
      const seen = new Set<number>();
      let cursor = total;
      let pages = 0;
      while (cursor > 0) {
        const page = handle.page(0, cursor);
        expect(page.rows.length).toBeGreaterThan(0);
        const ids = page.rows.map((r) => r.rowId);
        expect(Math.min(...ids)).toBe(page.beforeRowId);
        expect(Math.max(...ids)).toBe(cursor - 1);
        for (const id of ids) {
          expect(seen.has(id)).toBe(false);
          seen.add(id);
        }
        cursor = page.beforeRowId;
        pages++;
      }
      expect(seen.size).toBe(ROWS);
      expect(pages).toBe(Math.ceil(ROWS / TERMINAL_HISTORY_PAGE_ROWS));
    } finally {
      reader?.close();
      store.close();
    }
  }, 30_000);
});

describe("D4: retention", () => {
  test("run-level eviction moves firstRowId forward; a cursor below it is expired, not silently empty", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"), {
      runBytes: 3_000,
      machineBytes: 10 * 1024 * 1024,
    });
    try {
      const runId = crypto.randomUUID();
      const handle = store.openRun(runId);
      expect(handle.boundary().firstRowId).toBe(0);

      for (let i = 0; i < 100; i++) handle.append(row(80, "x".repeat(80)));
      handle.flush();

      const after = handle.boundary();
      expect(after.firstRowId).toBeGreaterThan(0);
      expect(after.status).toBe("recording"); // eviction is routine housekeeping, not a failure

      // Row 0 was reclaimed by the cap above; asking for it must say so.
      const evictedPage = handle.page(after.epoch, 1);
      expect(evictedPage.expired).toBe(true);
      expect(evictedPage.rows).toEqual([]);

      // A page still inside the retained window is ordinary, unexpired data.
      const livePage = handle.page(after.epoch, after.nextRowId);
      expect(livePage.expired).toBe(false);
      expect(livePage.rows.length).toBeGreaterThan(0);
    } finally {
      store.close();
    }
  });

  test("machine-level eviction reclaims the globally oldest rows across every run", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"), {
      runBytes: 10 * 1024 * 1024,
      machineBytes: 4_000,
    });
    try {
      const runA = crypto.randomUUID();
      const a = store.openRun(runA);
      for (let i = 0; i < 20; i++) a.append(row(80, "x".repeat(80)));
      a.flush();
      const aBefore = a.boundary();
      expect(aBefore.firstRowId).toBe(0); // run cap alone would not have evicted this

      const runB = crypto.randomUUID();
      const b = store.openRun(runB);
      for (let i = 0; i < 60; i++) b.append(row(80, "x".repeat(80)));
      b.flush();

      // B's growth pushed the MACHINE total over the cap; the globally
      // oldest rows are A's (it was written first), so A is the one that
      // moved even though nothing was ever written to A after the cap hit.
      const aAfter = a.boundary();
      expect(aAfter.firstRowId).toBeGreaterThan(aBefore.firstRowId);
      const page = a.page(aAfter.epoch, 1);
      expect(page.expired).toBe(true);
      expect(page.rows).toEqual([]);
    } finally {
      store.close();
    }
  });

  test("a drifted (inflated) byte counter costs one reconcile scan, not the run's real data", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"), {
      runBytes: 3_000,
      machineBytes: 10 * 1024 * 1024,
    });
    // `terminal_runs.bytes` is a trigger-maintained running total that
    // `evict()` trusts to decide HOW MUCH to delete without a SUM scan on the
    // common (nothing over budget) path — drive it out of sync with the real
    // rows the same way a partially-applied delete or an externally-edited
    // file would (see the doc comment on `evict()`), and prove the loop
    // reconciles from the true SUM before it deletes anything, rather than
    // deleting real rows until the (inflated) counter finally reads back
    // under the cap.
    const internal = store as unknown as { db: Database };
    try {
      const runId = crypto.randomUUID();
      const handle = store.openRun(runId);
      for (let i = 0; i < 5; i++) handle.append(row(80, "x".repeat(80)));
      handle.flush();
      const before = handle.boundary();
      expect(before.nextRowId).toBe(5); // well under the 3,000-byte cap — nothing evicted yet

      internal.db.query("UPDATE terminal_runs SET bytes = bytes + 1000000 WHERE runId = ?").run(runId);

      // One more append (well under the cap on its own) is enough to run
      // evict() again — with the counter drifted, evict() now believes this
      // run is ~1,000,000 bytes over budget.
      handle.append(row(80, "triggers evict() with the drifted counter"));
      handle.flush();

      const after = handle.boundary();
      // The pre-fix bug: evict()'s delete loop trusted the inflated counter
      // and kept deleting the OLDEST real rows (there being no way to tell a
      // genuine overage from a drifted one) until arithmetic on that same
      // inflated counter finally read back under budget — for a drift this
      // large, that means every real row, including the ones just appended.
      // The fix reconciles the counter from the true SUM(bytes) BEFORE the
      // delete loop runs at all, so with only ~500 real bytes on disk (well
      // under the 3,000 cap) nothing is deleted and every row survives.
      expect(after.nextRowId).toBe(6);
      const page = handle.page(after.epoch, after.nextRowId);
      expect(page.expired).toBe(false);
      expect(page.rows.length).toBe(6);
      expect(page.rows.map((r) => r.rowId)).toEqual([0, 1, 2, 3, 4, 5]);
    } finally {
      store.close();
    }
  });
});

describe("oversized history rows", () => {
  test("preserves earlier rows and visibly disables recording instead of creating a silent gap", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    try {
      const failures: Error[] = [];
      const handle = store.openRun(crypto.randomUUID(), (error) => failures.push(error));
      handle.append(row(80, "before the oversized row"));
      handle.append(row(80, "z".repeat(300_000)));
      handle.append(row(80, "after the oversized row"));
      const boundary = handle.boundary();
      expect(boundary.status).toBe("disabled");
      expect(failures).toHaveLength(1);
      expect(failures[0]!.message).toContain("page limit");
      expect(handle.page(boundary.epoch, boundary.nextRowId).rows.map(r => r.rowId)).toEqual([0]);
    } finally {
      store.close();
    }
  });
});

describe("D4: close() degrades", () => {
  test("a failing checkpoint/vacuum still lets close() release the DB connection", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    const internal = store as unknown as { db: Database };
    const originalExec = internal.db.exec.bind(internal.db);
    const originalClose = internal.db.close.bind(internal.db);
    let closeCalled = false;
    // Reached via a cast for the same reason as the disk-full test above:
    // `db` is private on purpose. Not restored in `finally` — `store` is
    // spent after `close()` either way, exactly like every other test in
    // this file that calls `store.close()` as its last act.
    internal.db.exec = ((sql: string) => {
      if (sql.includes("wal_checkpoint")) throw new Error("simulated checkpoint failure");
      return originalExec(sql);
    }) as typeof internal.db.exec;
    internal.db.close = (() => {
      closeCalled = true;
      return originalClose();
    }) as typeof internal.db.close;

    const runId = crypto.randomUUID();
    store.openRun(runId).append(row(80, "before close"));

    // The pre-fix bug: the checkpoint/vacuum and the close ran inside ONE
    // try/catch, so a thrown checkpoint skipped `this.db.close()` entirely —
    // the connection (and its -wal/-shm files) stayed open for the rest of
    // the process, which on Windows locks the path against the D3 startup
    // sweep on every later boot. The fix runs them as two separate
    // best-effort steps.
    expect(() => store.close()).not.toThrow();
    expect(closeCalled).toBe(true);
  });
});

describe("D4: crash tail", () => {
  test(
    "a transaction killed mid-flight (SIGKILL, no close()) leaves committed rows intact and the partial one absent",
    async () => {
      const dbPath = join(root, "crash.sqlite");
      const runId = crypto.randomUUID();
      const readyFile = join(root, "ready");
      const scriptPath = join(root, "crash-child.ts");
      const modUrl = pathToFileURL(join(import.meta.dir, "..", "src", "terminal-frames", "history.ts")).href;

      const safeCount = 5;
      // Large enough that the COMMIT loop itself (the part under test) takes
      // a while even on fast hardware — we kill moments after the ready
      // signal, so the actual test time is short regardless of this number;
      // its only job is to make sure the kill lands INSIDE the transaction.
      const bigCount = 400_000;
      const textLen = 200;

      writeFileSync(
        scriptPath,
        [
          "const [, , modUrl, dbPath, runId, readyFile, safeCount, bigCount, textLen] = Bun.argv;",
          "const { TerminalHistoryStore } = await import(modUrl);",
          "const { writeFileSync } = await import('node:fs');",
          "function rows(start, count, len) {",
          "  const text = 'y'.repeat(Number(len));",
          "  const out = [];",
          "  for (let i = 0; i < Number(count); i++) {",
          "    out.push({ rowId: Number(start) + i, cols: 80, wrapped: false,",
          "      spans: [{ text, cells: text.length, sgr: '\\x1b[0m' }] });",
          "  }",
          "  return out;",
          "}",
          "const store = new TerminalHistoryStore(dbPath);",
          "store.openRun(runId);",
          "store.commit(runId, 0, Number(safeCount), rows(0, safeCount, 4));",
          // Built BEFORE the ready signal, deliberately: constructing a
          // 400,000-element array is itself measurable (tens of ms), and if
          // it happened AFTER writeFileSync the parent's kill could land
          // during array construction — before store.commit() even starts —
          // which would make every run look atomic whether or not it truly
          // is. Only the DB write loop itself may be inside the timed window.
          "const bigRows = rows(Number(safeCount), bigCount, textLen);",
          "writeFileSync(readyFile, 'ready');",
          // Never expected to finish — the parent kills this process shortly
          // after observing readyFile. If it somehow did finish, the test
          // below would still correctly fail (the big batch would be found
          // fully present, not absent), so there is no silent false pass.
          "store.commit(runId, 0, Number(safeCount) + Number(bigCount), bigRows);",
          "",
        ].join("\n"),
      );

      const child = Bun.spawn(
        [
          process.execPath, "run", scriptPath,
          modUrl, dbPath, runId, readyFile, String(safeCount), String(bigCount), String(textLen),
        ],
        { stdout: "ignore", stderr: "inherit" },
      );
      try {
        expect(await waitUntil(() => existsSync(readyFile), 20_000)).toBe(true);
        child.kill(); // SIGKILL-equivalent process termination — not a close().
        await child.exited;
      } finally {
        try { child.kill(); } catch { /* already exited */ }
      }

      // Reopen as a fresh connection — a real crash-recovery read, not the
      // handle that was just killed.
      const reopened = new TerminalHistoryStore(dbPath);
      try {
        const record = reopened.record(runId);
        expect(record).not.toBeNull();
        expect(record!.nextRowId).toBe(safeCount); // the big commit never advanced this

        const raw = new Database(dbPath, { readonly: true });
        try {
          const counted = raw
            .query<{ c: number; maxId: number | null }, [string]>(
              "SELECT COUNT(*) AS c, MAX(rowId) AS maxId FROM terminal_rows WHERE runId = ?",
            )
            .get(runId)!;
          expect(counted.c).toBe(safeCount); // none of the big batch survived
          expect(counted.maxId).toBe(safeCount - 1);
        } finally {
          raw.close();
        }

        // The safe batch itself reads back whole and in order.
        const page = reopened.read(runId, 0, safeCount);
        expect(page.map((r) => r.rowId)).toEqual([0, 1, 2, 3, 4]);
      } finally {
        reopened.close();
      }
    },
    60_000,
  );
});

describe("D4: disk full", () => {
  test("a write failure disables the handle, boundary().status becomes disabled, reads keep working, and nothing throws", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    // Simulate SQLITE_FULL without touching the OS: `db.transaction` is what
    // every WRITE path (commit, clear) runs through, so making it throw
    // exactly as SQLite does on a full disk is a faithful, portable stand-in
    // for a real quota failure — the alternative (chmod a file read-only)
    // does not work here because a POSIX/Windows permission check applies at
    // open() time, not to writes through an already-open handle. Reached via
    // a cast because `db` is private to TerminalHistoryStore on purpose (no
    // client may ever construct or swap one); always restored in `finally`
    // so a later assertion failure can never leak the patch into another
    // test's store (a fresh instance each time, but the same class).
    const internal = store as unknown as { db: Database };
    const originalTransaction = internal.db.transaction.bind(internal.db);
    try {
      const runId = crypto.randomUUID();
      const handle = store.openRun(runId);
      handle.append(row(80, "before the disk fills"));
      handle.flush();
      expect(handle.boundary().nextRowId).toBe(1);

      internal.db.transaction = (() => () => {
        throw new Error("SQLITE_FULL: database or disk is full");
      }) as unknown as typeof internal.db.transaction;

      expect(() => {
        handle.append(row(80, "after the disk fills"));
        handle.flush();
      }).not.toThrow();
      expect(handle.boundary().status).toBe("disabled");

      // Live viewing is unaffected: the row committed before the failure
      // still reads back, through the SAME handle.
      expect(() => handle.page(0, 1)).not.toThrow();
      const page = handle.page(0, 1);
      expect(page.rows.map((r) => r.rowId)).toEqual([0]);

      // nextRowId is bumped in append() BEFORE the row is committed, so the
      // one failed write above still burned rowId 1 — it is never reused,
      // but it was also never persisted (page() below proves that half).
      expect(handle.boundary().nextRowId).toBe(2);

      // Once disabled, further append/flush calls are silently inert rather
      // than throwing, and never advance nextRowId further — append()
      // short-circuits on `this.disabled` before it ever queues a row.
      expect(() => {
        handle.append(row(80, "still nothing"));
        handle.flush();
      }).not.toThrow();
      expect(handle.boundary().nextRowId).toBe(2); // the post-disable append never even queued

      // The one row that DID commit (rowId 0) is still all that is there —
      // the burned rowId 1 truly never landed, despite nextRowId claiming it.
      const survivors = handle.page(0, handle.boundary().nextRowId);
      expect(survivors.rows.map((r) => r.rowId)).toEqual([0]);

      // clear() is not gated on `disabled` (D5: it resets in-memory state
      // unconditionally) and must still not throw even though the DELETE
      // underneath it fails the same way every other write does right now.
      expect(() => handle.clear()).not.toThrow();
    } finally {
      internal.db.transaction = originalTransaction;
      store.close();
    }
  });
});

describe("D5: clear/epoch and resize semantics", () => {
  test("clear() advances the epoch even when the DELETE fails; a page carrying the old epoch is expired, never served", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    const internal = store as unknown as { db: Database };
    const originalQuery = internal.db.query.bind(internal.db);
    try {
      const runId = crypto.randomUUID();
      const handle = store.openRun(runId);
      handle.append(row(80, "row zero"));
      handle.flush();
      const before = handle.boundary();
      expect(before.epoch).toBe(0);

      // Force the DELETE half of store.clear() to fail while leaving every
      // other query (including the epoch UPDATE, if reached) alone.
      internal.db.query = ((sql: string) => {
        if (sql.startsWith("DELETE FROM terminal_rows")) throw new Error("simulated DELETE failure");
        return originalQuery(sql);
      }) as typeof internal.db.query;

      expect(() => handle.clear()).not.toThrow();

      const after = handle.boundary();
      // Pinned: the in-memory epoch is bumped unconditionally by clear(),
      // before the (here, failing) DELETE ever runs — cleared history must
      // not reappear through this handle just because the disk-side delete
      // lost.
      expect(after.epoch).toBe(before.epoch + 1);

      // A cursor carrying the OLD epoch — even one still physically on disk,
      // since the DELETE never landed — must come back expired, not served.
      const stalePage = handle.page(before.epoch, before.nextRowId);
      expect(stalePage.expired).toBe(true);
      expect(stalePage.rows).toEqual([]);
    } finally {
      internal.db.query = originalQuery;
      store.close();
    }
  });

  test("a shrink then a grow does not renumber or duplicate a rowId already published; each row keeps its own geometry", () => {
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    try {
      const runId = crypto.randomUUID();
      const handle = store.openRun(runId);

      const wide = 5;
      const narrow = 5;
      const wideAgain = 5;
      for (let i = 0; i < wide; i++) handle.append(row(80, `wide${i}`));
      for (let i = 0; i < narrow; i++) handle.append(row(40, `narrow${i}`)); // shrink
      for (let i = 0; i < wideAgain; i++) handle.append(row(100, `wideagain${i}`)); // grow past original
      handle.flush();

      const total = wide + narrow + wideAgain;
      const boundary = handle.boundary();
      expect(boundary.nextRowId).toBe(total);

      const page = handle.page(boundary.epoch, boundary.nextRowId);
      expect(page.rows.map((r) => r.rowId)).toEqual(Array.from({ length: total }, (_, i) => i));

      // Original per-row geometry is preserved — a later resize never
      // rewrites an already-archived row's `cols`.
      expect(page.rows.slice(0, wide).every((r) => r.cols === 80)).toBe(true);
      expect(page.rows.slice(wide, wide + narrow).every((r) => r.cols === 40)).toBe(true);
      expect(page.rows.slice(wide + narrow).every((r) => r.cols === 100)).toBe(true);
    } finally {
      store.close();
    }
  });
});

describe("D1: a caller's onFailure cannot escape", () => {
  test("a throwing onFailure is contained by every method that reports one, and the handle still disables", () => {
    // The defect this wave was chartered on. `attempt()` reports a store
    // failure from INSIDE its own catch, so before the fix a throwing
    // caller-supplied callback rode that stack out through append() into
    // xterm's parse loop and the PTY flush above it — one bad callback taking
    // down every terminal on the machine. Nothing else in the suite passes a
    // callback that throws, so without this test deleting the guard leaves
    // the whole suite green.
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    const internal = store as unknown as { db: Database };
    const originalTransaction = internal.db.transaction.bind(internal.db);
    try {
      let reported = 0;
      const handle = store.openRun(crypto.randomUUID(), () => {
        reported++;
        throw new Error("this caller's failure handler is broken");
      });
      handle.append(row(80, "before the disk fills"));
      handle.flush();

      internal.db.transaction = (() => () => {
        throw new Error("SQLITE_FULL: database or disk is full");
      }) as unknown as typeof internal.db.transaction;

      expect(() => {
        handle.append(row(80, "after the disk fills"));
        handle.flush();
      }).not.toThrow();
      expect(reported).toBe(1);
      // Contained, not skipped: the handle still latched, so the failure is
      // still reported through the channel that does not depend on a caller
      // behaving (`boundary().status`, which the frame carries).
      expect(handle.boundary().status).toBe("disabled");

      // The remaining four public methods, on a handle whose callback throws
      // and whose store is still failing.
      expect(() => handle.clear()).not.toThrow();
      expect(() => handle.boundary()).not.toThrow();
      expect(() => handle.page(handle.boundary().epoch, 1)).not.toThrow();
      expect(() => handle.retire()).not.toThrow();
      // Still exactly one report: onFailure fires on the FIRST failure only,
      // so a broken callback cannot be re-entered by every later write either.
      expect(reported).toBe(1);
    } finally {
      internal.db.transaction = originalTransaction;
      store.close();
    }
  });

  test("page() answers an unusable cursor as expired instead of throwing", () => {
    // `page` is the one method a CLIENT's own number reaches. Its bounds
    // check sat outside `attempt()`, so a cursor the wire schema happened not
    // to reject would raise out of the delivery path rather than telling the
    // app to re-read the boundary.
    const store = new TerminalHistoryStore(join(root, "history.sqlite"));
    try {
      const handle = store.openRun(crypto.randomUUID());
      handle.append(row(80, "a real row"));
      handle.flush();
      const epoch = handle.boundary().epoch;

      for (const cursor of [-1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER + 2, "5" as unknown as number]) {
        let page: ReturnType<typeof handle.page> | undefined;
        expect(() => { page = handle.page(epoch, cursor); }).not.toThrow();
        expect(page!.expired).toBe(true);
        expect(page!.rows).toEqual([]);
      }

      // A sound cursor still pages normally afterwards — the guard rejects
      // the value, never the handle.
      expect(handle.page(epoch, 1).rows.map((r) => r.rowId)).toEqual([0]);
    } finally {
      store.close();
    }
  });
});
