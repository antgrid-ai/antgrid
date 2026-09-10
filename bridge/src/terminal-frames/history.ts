import { Database } from "bun:sqlite";
import { z } from "zod";
import {
  TERMINAL_HISTORY_MACHINE_BYTES, TERMINAL_HISTORY_PAGE_BYTES,
  TERMINAL_HISTORY_PAGE_ROWS, TERMINAL_HISTORY_RUN_BYTES,
  TerminalHistoryRowSchema,
  type TerminalHistoryBoundary, type TerminalHistoryRow,
} from "./protocol";

export interface HistoryPage {
  history: TerminalHistoryBoundary;
  expired: boolean;
  beforeRowId: number;
  rows: TerminalHistoryRow[];
}

interface RunRecord { epoch: number; nextRowId: number; bytes: number }
interface StoredRow { payload: string; bytes: number; rowId: number; serial: number }
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
      CREATE TRIGGER IF NOT EXISTS terminal_row_insert AFTER INSERT ON terminal_rows
        BEGIN UPDATE terminal_runs SET bytes = bytes + new.bytes WHERE runId = new.runId; END;
      CREATE TRIGGER IF NOT EXISTS terminal_row_delete AFTER DELETE ON terminal_rows
        BEGIN UPDATE terminal_runs SET bytes = bytes - old.bytes WHERE runId = old.runId; END;
    `);
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

  private evict(runId: string): void {
    let runBytes = this.record(runId)!.bytes;
    while (runBytes > this.limits.runBytes) {
      const row = this.db.query<StoredRow, [string]>(
        "SELECT serial, bytes FROM terminal_rows WHERE runId = ? ORDER BY epoch, rowId LIMIT 1",
      ).get(runId)!;
      this.db.query("DELETE FROM terminal_rows WHERE serial = ?").run(row.serial);
      runBytes -= row.bytes;
    }
    let total = this.db.query<{ bytes: number }, []>("SELECT COALESCE(SUM(bytes), 0) AS bytes FROM terminal_runs").get()!.bytes;
    while (total > this.limits.machineBytes) {
      const row = this.db.query<StoredRow, []>("SELECT serial, bytes FROM terminal_rows ORDER BY serial LIMIT 1").get()!;
      this.db.query("DELETE FROM terminal_rows WHERE serial = ?").run(row.serial);
      total -= row.bytes;
    }
  }

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
    let bytes = 1024;
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

  deleteRun(runId: string): void {
    this.handles.get(runId)?.retire();
    this.handles.delete(runId);
    this.db.query("DELETE FROM terminal_runs WHERE runId = ?").run(runId);
  }

  close(): void {
    for (const handle of this.handles.values()) { handle.flush(); handle.retire(); }
    this.handles.clear();
    this.db.exec("PRAGMA wal_checkpoint(TRUNCATE); PRAGMA incremental_vacuum;");
    this.db.close();
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
      if (bytes > TERMINAL_HISTORY_PAGE_BYTES - 1024) throw new Error("Terminal history row exceeds page limit");
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
    z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER).parse(beforeRowId);
    const history = this.boundary();
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
      if (firstFailure) this.onFailure(error instanceof Error ? error : new Error(String(error)));
    }
  }
}
