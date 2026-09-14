import { Database } from "bun:sqlite";
import { z } from "zod";
import {
  TERMINAL_HISTORY_MACHINE_BYTES, TERMINAL_HISTORY_PAGE_BYTES,
  TERMINAL_HISTORY_PAGE_ROWS, TERMINAL_HISTORY_RUN_BYTES,
  TerminalHistoryRowSchema,
  type TerminalHistoryBoundary, type TerminalHistoryRow,
  TerminalScreenFrameSchema, type TerminalScreenFrame,
} from "./protocol";

export interface HistoryPage {
  history: TerminalHistoryBoundary;
  expired: boolean;
  beforeRowId: number;
  rows: TerminalHistoryRow[];
}

interface RunRecord { epoch: number; nextRowId: number; bytes: number }
interface StoredRow { payload: string; bytes: number; rowId: number; serial: number }

// Room read() reserves per page for the envelope/boundary, plus the one-byte
// separator it counts per row (see read()). append()'s per-row cap is derived
// from the same number so a row it accepts can never be the one row a page can't
// return: keep the two in lockstep rather than duplicating the literal.
const PAGE_ENVELOPE_BYTES = 1024;
const MAX_ROW_BYTES = TERMINAL_HISTORY_PAGE_BYTES - PAGE_ENVELOPE_BYTES - 1;

const optionsSchema = z.object({
  runBytes: z.number().int().positive().default(TERMINAL_HISTORY_RUN_BYTES),
  machineBytes: z.number().int().positive().default(TERMINAL_HISTORY_MACHINE_BYTES),
});

/** One machine-owned database. Callers resolve run IDs from session ownership,
 * never from a client-provided filesystem path. SQLite's transactions recover
 * complete records without replaying raw PTY output after a crash. */
export class TerminalHistoryStore {
  private readonly db: Database;
  private readonly limits: z.infer<typeof optionsSchema>;
  private readonly handles = new Map<string, TerminalRunHistory>();

  constructor(path: string, options: z.input<typeof optionsSchema> = {}) {
    this.limits = optionsSchema.parse(options);
    this.db = new Database(path, { create: true, strict: true });
    this.db.exec(`
      PRAGMA auto_vacuum = INCREMENTAL;
      PRAGMA journal_mode = WAL;
      PRAGMA synchronous = FULL;
      PRAGMA foreign_keys = ON;
      PRAGMA journal_size_limit = 1048576;
      CREATE TABLE IF NOT EXISTS terminal_runs (
        runId TEXT PRIMARY KEY, epoch INTEGER NOT NULL DEFAULT 0,
        nextRowId INTEGER NOT NULL DEFAULT 0, bytes INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS terminal_rows (
        serial INTEGER PRIMARY KEY AUTOINCREMENT,
        runId TEXT NOT NULL REFERENCES terminal_runs(runId) ON DELETE CASCADE,
        epoch INTEGER NOT NULL, rowId INTEGER NOT NULL,
        payload TEXT NOT NULL, bytes INTEGER NOT NULL,
        UNIQUE(runId, epoch, rowId)
      );
      CREATE TABLE IF NOT EXISTS terminal_owners (
        runId TEXT PRIMARY KEY REFERENCES terminal_runs(runId) ON DELETE CASCADE,
        scope TEXT NOT NULL, terminalId TEXT NOT NULL, created INTEGER NOT NULL,
        finalFrame TEXT, storedBytes INTEGER NOT NULL DEFAULT 0
      );
      CREATE INDEX IF NOT EXISTS terminal_owner_lookup ON terminal_owners(scope, terminalId, created DESC);
      CREATE TRIGGER IF NOT EXISTS terminal_row_insert AFTER INSERT ON terminal_rows
        BEGIN UPDATE terminal_runs SET bytes = bytes + new.bytes WHERE runId = new.runId; END;
      CREATE TRIGGER IF NOT EXISTS terminal_row_delete AFTER DELETE ON terminal_rows
        BEGIN UPDATE terminal_runs SET bytes = bytes - old.bytes WHERE runId = old.runId; END;
    `);
    const columns = this.db.query<{ name: string }, []>("PRAGMA table_info(terminal_owners)").all();
    if (!columns.some((column) => column.name === "storedBytes")) {
      this.db.exec("ALTER TABLE terminal_owners ADD COLUMN storedBytes INTEGER NOT NULL DEFAULT 0");
    }
    this.db.exec(`
      UPDATE terminal_owners SET storedBytes = 128 + length(CAST(scope AS BLOB)) + length(CAST(terminalId AS BLOB))
        + COALESCE(length(CAST(finalFrame AS BLOB)), 0);
      CREATE TRIGGER IF NOT EXISTS terminal_owner_insert AFTER INSERT ON terminal_owners
        BEGIN UPDATE terminal_runs SET bytes = bytes + new.storedBytes WHERE runId = new.runId; END;
      CREATE TRIGGER IF NOT EXISTS terminal_owner_update AFTER UPDATE OF storedBytes ON terminal_owners
        BEGIN UPDATE terminal_runs SET bytes = bytes + new.storedBytes - old.storedBytes WHERE runId = new.runId; END;
    `);
    this.reconcileAllBytes();
  }

  openRun(runId: string, onFailure: (error: Error) => void = () => {}): TerminalRunHistory {
    z.uuid().parse(runId);
    const existing = this.handles.get(runId);
    if (existing) return existing;
    this.db.query("INSERT OR IGNORE INTO terminal_runs(runId) VALUES (?)").run(runId);
    const record = this.record(runId)!;
    const handle = new TerminalRunHistory(this, runId, record, onFailure);
    this.handles.set(runId, handle);
    return handle;
  }

  record(runId: string): RunRecord | null {
    return this.db.query<RunRecord, [string]>(
      "SELECT epoch, nextRowId, bytes FROM terminal_runs WHERE runId = ?",
    ).get(runId);
  }

  bindRun(runId: string, scope: string, terminalId: string): void {
    this.db.transaction(() => {
      this.db.query("INSERT OR IGNORE INTO terminal_owners(runId, scope, terminalId, created, storedBytes) VALUES (?, ?, ?, ?, ?)")
        .run(runId, scope, terminalId, Date.now(), 128 + Buffer.byteLength(scope) + Buffer.byteLength(terminalId));
      this.evict(runId);
    })();
  }

  ownsRun(runId: string, scope: string, terminalId: string): boolean {
    return !!this.db.query("SELECT 1 FROM terminal_owners WHERE runId = ? AND scope = ? AND terminalId = ?")
      .get(runId, scope, terminalId);
  }

  terminalIds(scope: string): string[] {
    return this.db.query<{ terminalId: string }, [string]>(
      "SELECT DISTINCT terminalId FROM terminal_owners WHERE scope = ? ORDER BY terminalId",
    ).all(scope).map((row) => row.terminalId);
  }

  saveFinal(runId: string, frame: TerminalScreenFrame): void {
    const payload = JSON.stringify(TerminalScreenFrameSchema.parse(frame));
    this.db.transaction(() => {
      this.db.query(`UPDATE terminal_owners SET finalFrame = ?, storedBytes =
        128 + length(CAST(scope AS BLOB)) + length(CAST(terminalId AS BLOB)) + ? WHERE runId = ?`)
        .run(payload, Buffer.byteLength(payload), runId);
      this.evict(runId);
    })();
  }

  latestFinal(scope: string, terminalId: string): { runId: string; frame?: TerminalScreenFrame } | undefined {
    const row = this.db.query<{ runId: string; finalFrame: string | null }, [string, string]>(
      "SELECT runId, finalFrame FROM terminal_owners WHERE scope = ? AND terminalId = ? ORDER BY created DESC LIMIT 1",
    ).get(scope, terminalId);
    if (!row) return undefined;
    if (row.finalFrame === null) return { runId: row.runId };
    const parsed = TerminalScreenFrameSchema.safeParse(JSON.parse(row.finalFrame));
    return { runId: row.runId, frame: parsed.success ? parsed.data : undefined };
  }

  releaseRun(runId: string): void {
    this.handles.get(runId)?.flush();
    this.handles.get(runId)?.retire();
    this.handles.delete(runId);
  }

  deleteTerminal(scope: string, terminalId: string): void {
    const runs = this.db.query<{ runId: string }, [string, string]>(
      "SELECT runId FROM terminal_owners WHERE scope = ? AND terminalId = ?",
    ).all(scope, terminalId);
    for (const run of runs) this.deleteRun(run.runId);
  }

  commit(runId: string, epoch: number, nextRowId: number, rows: readonly TerminalHistoryRow[]): void {
    this.db.transaction(() => {
      const insert = this.db.query("INSERT INTO terminal_rows(runId, epoch, rowId, payload, bytes) VALUES (?, ?, ?, ?, ?)");
      for (const row of rows) {
        const payload = JSON.stringify(row);
        insert.run(runId, epoch, row.rowId, payload, Buffer.byteLength(payload));
      }
      this.db.query("UPDATE terminal_runs SET nextRowId = ? WHERE runId = ?").run(nextRowId, runId);
      this.evict(runId);
    })();
  }

  // The `bytes` columns are trigger-maintained running totals, kept only so the COMMON
  // path (nothing to evict) never needs a SUM scan. Both loops below drive on them once
  // eviction is actually triggered, so a drifted counter (a partially-applied delete, a
  // file edited outside this process) must not dictate how much gets deleted. Reconcile
  // BEFORE the first delete, not after the rows are already gone: reconciling only on an
  // empty row query still drains every real row belonging to the drifted counter first —
  // the SELECT that drives each loop doesn't know the difference between "genuinely this
  // much over budget" and "counter says so", so it keeps finding real rows to delete
  // until the (drifted) running total finally reads back under the limit, which for an
  // inflated counter means the whole run (or, at the machine level, every run) first.
  // Reconciling once, up front, the moment the (possibly drifted) counter says eviction
  // is needed costs one extra scan on a drifted counter and nothing on a sound one — the
  // loop's own arithmetic stays accurate afterwards, since nothing else mutates `bytes`
  // between here and the loop's own deletes.
  private evict(runId: string): void {
    let runBytes = this.record(runId)!.bytes;
    if (runBytes > this.limits.runBytes) {
      this.reconcileRunBytes(runId);
      runBytes = this.record(runId)!.bytes;
    }
    while (runBytes > this.limits.runBytes) {
      const row = this.db.query<StoredRow, [string]>(
        "SELECT serial, bytes FROM terminal_rows WHERE runId = ? ORDER BY epoch, rowId LIMIT 1",
      ).get(runId);
      if (!row) {
        if (this.evictFinal(runId)) { runBytes = this.record(runId)!.bytes; continue; }
        break;
      }
      this.db.query("DELETE FROM terminal_rows WHERE serial = ?").run(row.serial);
      runBytes -= row.bytes;
    }
    let total = this.db.query<{ bytes: number }, []>("SELECT COALESCE(SUM(bytes), 0) AS bytes FROM terminal_runs").get()!.bytes;
    if (total > this.limits.machineBytes) {
      this.reconcileAllBytes();
      total = this.db.query<{ bytes: number }, []>("SELECT COALESCE(SUM(bytes), 0) AS bytes FROM terminal_runs").get()!.bytes;
    }
    while (total > this.limits.machineBytes) {
      const row = this.db.query<StoredRow, []>("SELECT serial, bytes FROM terminal_rows ORDER BY serial LIMIT 1").get();
      if (!row) {
        const owners = this.db.query<{ runId: string; finalFrame: string | null }, []>(
          "SELECT runId, finalFrame FROM terminal_owners ORDER BY created, rowid",
        ).all();
        const final = owners.find((owner) => owner.finalFrame !== null);
        if (final) this.evictFinal(final.runId);
        else {
          const inactive = owners.find((owner) => !this.handles.has(owner.runId));
          if (!inactive) break;
          this.deleteRun(inactive.runId);
        }
        total = this.db.query<{ bytes: number }, []>("SELECT COALESCE(SUM(bytes), 0) AS bytes FROM terminal_runs").get()!.bytes;
        continue;
      }
      this.db.query("DELETE FROM terminal_rows WHERE serial = ?").run(row.serial);
      total -= row.bytes;
    }
  }

  private evictFinal(runId: string): boolean {
    return this.db.query(`UPDATE terminal_owners SET finalFrame = NULL,
      storedBytes = 128 + length(CAST(scope AS BLOB)) + length(CAST(terminalId AS BLOB))
      WHERE runId = ? AND finalFrame IS NOT NULL`).run(runId).changes > 0;
  }

  private reconcileRunBytes(runId: string): void {
    const actual = this.db.query<{ bytes: number }, [string]>(
      "SELECT COALESCE(SUM(bytes), 0) + COALESCE((SELECT storedBytes FROM terminal_owners WHERE runId = ?1), 0) AS bytes FROM terminal_rows WHERE runId = ?1",
    ).get(runId)!.bytes;
    this.db.query("UPDATE terminal_runs SET bytes = ? WHERE runId = ?").run(actual, runId);
  }

  private reconcileAllBytes(): void {
    this.db.exec(
      "UPDATE terminal_runs SET bytes = (SELECT COALESCE(SUM(bytes), 0) FROM terminal_rows WHERE terminal_rows.runId = terminal_runs.runId) + COALESCE((SELECT storedBytes FROM terminal_owners WHERE terminal_owners.runId = terminal_runs.runId), 0)",
    );
  }

  // Deletes every row for the run, not just the rows under its current epoch — clear
  // is a hard reset, not a per-epoch trim. This is also what keeps a failed clear from
  // leaving orphans: TerminalRunHistory.clear() advances its in-memory epoch before
  // this call and keeps it advanced even if the transaction below throws, so any rows
  // this DELETE didn't reach sit under an epoch the handle will never query again.
  // Deleting unconditionally here (rather than `AND epoch = ?`) means a retried or
  // later clear still reaches them, and if the run keeps recording, ordinary eviction
  // (oldest epoch first, see evict()) reclaims them regardless.
  clear(runId: string, epoch: number): void {
    this.db.transaction(() => {
      this.db.query("DELETE FROM terminal_rows WHERE runId = ?").run(runId);
      this.db.query("UPDATE terminal_runs SET epoch = ?, nextRowId = 0 WHERE runId = ?").run(epoch, runId);
    })();
  }

  firstRowId(runId: string, epoch: number, nextRowId: number): number {
    return this.db.query<{ rowId: number }, [string, number]>(
      "SELECT rowId FROM terminal_rows WHERE runId = ? AND epoch = ? ORDER BY rowId LIMIT 1",
    ).get(runId, epoch)?.rowId ?? nextRowId;
  }

  read(runId: string, epoch: number, beforeRowId: number): TerminalHistoryRow[] {
    const rows: TerminalHistoryRow[] = [];
    // Reserve room for the envelope/boundary; the page limit is UTF-8 wire bytes.
    let bytes = PAGE_ENVELOPE_BYTES;
    const query = this.db.query<StoredRow, [string, number, number, number]>(
      "SELECT payload, bytes, rowId FROM terminal_rows WHERE runId = ? AND epoch = ? AND rowId < ? ORDER BY rowId DESC LIMIT ?",
    );
    for (const row of query.iterate(runId, epoch, beforeRowId, TERMINAL_HISTORY_PAGE_ROWS)) {
      if (bytes + row.bytes + 1 > TERMINAL_HISTORY_PAGE_BYTES) break;
      rows.push(TerminalHistoryRowSchema.parse(JSON.parse(row.payload)));
      bytes += row.bytes + 1;
    }
    return rows.reverse();
  }

  // The ON DELETE CASCADE removes every matching terminal_rows row as part of this one
  // statement, and (verified: SQLite fires a child table's own triggers for FK-cascaded
  // deletes regardless of the recursive_triggers setting) terminal_row_delete runs for
  // each of them — so terminal_runs.bytes is walked back to zero before the row itself
  // disappears. It does not need to be: the row vanishes in the same statement either way.
  deleteRun(runId: string): void {
    this.handles.get(runId)?.retire();
    this.handles.delete(runId);
    this.db.query("DELETE FROM terminal_runs WHERE runId = ?").run(runId);
  }

  // Best-effort teardown: this runs on host shutdown, which has nothing left to retry
  // against and nothing to hand a thrown error to. A checkpoint/vacuum/close failure
  // (disk full, the file already gone) must not throw out of shutdown — the WAL is
  // durable on its own and SQLite replays it on the next open regardless.
  //
  // The checkpoint/vacuum and the close are two SEPARATE best-effort steps, not one:
  // a failing checkpoint must not skip the close, or the connection (and its `-wal`/
  // `-shm` files) stays open for the rest of the process — on Windows that locks the
  // path against the D3 startup sweep on every later boot.
  close(): void {
    for (const handle of this.handles.values()) { handle.flush(); handle.retire(); }
    this.handles.clear();
    try {
      this.db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum;");
    } catch { /* see doc comment above */ }
    try {
      this.db.close();
    } catch { /* see doc comment above */ }
  }
}

export class TerminalRunHistory {
  private epoch: number;
  private nextRowId: number;
  private pending: TerminalHistoryRow[] = [];
  private pendingBytes = 0;
  private disabled = false;
  private retired = false;

  constructor(
    private readonly store: TerminalHistoryStore,
    readonly runId: string,
    record: RunRecord,
    private readonly onFailure: (error: Error) => void,
  ) { this.epoch = record.epoch; this.nextRowId = record.nextRowId; }

  append(row: Omit<TerminalHistoryRow, "rowId">): void {
    if (this.retired || this.disabled) return;
    this.attempt(() => {
      const record = TerminalHistoryRowSchema.parse({ ...row, rowId: this.nextRowId });
      const bytes = Buffer.byteLength(JSON.stringify(record));
      if (bytes > MAX_ROW_BYTES) {
        this.flush();
        throw new Error("Terminal history row exceeds the page limit; history recording stopped.");
      }
      if (this.pendingBytes + bytes > TERMINAL_HISTORY_PAGE_BYTES) this.flush();
      if (this.disabled) return;
      this.nextRowId++;
      this.pending.push(record);
      this.pendingBytes += bytes;
      if (this.pending.length >= TERMINAL_HISTORY_PAGE_ROWS) this.flush();
    });
  }

  flush(): void {
    if (this.retired || this.disabled || !this.pending.length) return;
    this.attempt(() => {
      this.store.commit(this.runId, this.epoch, this.nextRowId, this.pending);
      this.pending = [];
      this.pendingBytes = 0;
    });
  }

  clear(): void {
    if (this.retired) return;
    this.pending = [];
    this.pendingBytes = 0;
    this.epoch++;
    this.nextRowId = 0;
    // In-memory epoch advances even on disk failure: cleared history must not
    // reappear through this handle just because a DELETE could not commit.
    this.attempt(() => this.store.clear(this.runId, this.epoch));
  }

  boundary(): TerminalHistoryBoundary {
    this.flush();
    let firstRowId = this.nextRowId;
    this.attempt(() => { firstRowId = this.store.firstRowId(this.runId, this.epoch, this.nextRowId); });
    return { epoch: this.epoch, firstRowId, nextRowId: this.nextRowId, status: this.disabled ? "disabled" : "recording" };
  }

  page(epoch: number, beforeRowId: number): HistoryPage {
    // Answered as an expired cursor rather than thrown. This class's contract
    // is that no method raises once the run is open (see `attempt`), and a
    // cursor that is not a safe non-negative integer is exactly what `expired`
    // already means to the app: stop paging from it and re-read the boundary.
    // The wire schema rejects these first today, but `page` is the one method
    // a client's own number reaches, so it must not depend on that.
    const cursor = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).safeParse(beforeRowId);
    const history = this.boundary();
    if (!cursor.success) return { history, expired: true, beforeRowId: history.nextRowId, rows: [] };
    const expired = epoch !== history.epoch || beforeRowId < history.firstRowId;
    const before = Math.min(beforeRowId, history.nextRowId);
    let rows: TerminalHistoryRow[] = [];
    if (!expired && !this.retired) this.attempt(() => { rows = this.store.read(this.runId, epoch, before); });
    return { history, expired, beforeRowId: rows[0]?.rowId ?? before, rows };
  }

  retire(): void { this.retired = true; this.pending = []; this.pendingBytes = 0; }

  private attempt(operation: () => void): void {
    try { operation(); } catch (error) {
      const firstFailure = !this.disabled;
      this.disabled = true;
      this.pending = [];
      this.pendingBytes = 0;
      if (firstFailure) {
        // onFailure is caller-supplied. Reporting it from inside this catch, unguarded,
        // would let a throwing callback escape append -> the xterm parse loop -> the PTY
        // flush stack and take down every terminal on the machine (the TS-3 shape).
        try {
          this.onFailure(error instanceof Error ? error : new Error(String(error)));
        } catch { /* swallow: the callback already had its chance to observe the failure */ }
      }
    }
  }
}
