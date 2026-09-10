// The one database the session bus keeps, and the only place it is opened.
//
// One machine-level file rather than a tree of per-session JSON, because every
// store here is written on a message event and read back by whoever happens to
// hold the session next. Whole-file rewrite could express neither of the two
// things that actually matter: a writer that knows only its OWN rows (two hosts
// on one ANTGRID_DIR is a documented setup, so silence about a row is never
// permission to delete it), and a reclaim narrower than a directory.
//
// OPENED PER OPERATION AND CLOSED IN A `finally`, which is the shape the two
// bun:sqlite call sites this bridge already ships use (agents/codex/title.ts,
// agents/opencode/db-read.ts). A cached handle would be faster and would cost
// three things this is not worth: a close wired into HostServer.shutdown, an
// afterEach in every suite that mkdtemps an abDir, and a Windows EBUSY the
// first time either is forgotten. The bus writes on message events, not in a
// loop; if that ever stops being true, measure before caching.
//
// Nothing here throws. A caller that cannot reach the database gets the EMPTY
// store, which is the answer every one of them already folds from, and the
// failure is SAID once per process with the error that caused it. A store that
// empties itself in silence is the trap: for the machine-level routes that is
// every project's carrier bindings gone with no line anywhere to name why.

import { Database } from "bun:sqlite";
import type { z } from "zod";
import { chmodSync, mkdirSync, renameSync, rmSync } from "node:fs";
import { join } from "node:path";
import { logger } from "../logger";

const log = logger.child({ component: "session-bus" });

/** Bumped for ANY schema change. There is no migration and there will not be
 *  one before v1: a mismatch DROPS every table and starts clean. Stated as a
 *  version rather than left implicit because the trap is the other behaviour —
 *  a schema check that quietly reads rows written under a shape this code no
 *  longer holds. Losing bus state costs a relearned route and a redelivered
 *  message, both of which the protocol already tolerates. */
export const BUS_DB_VERSION = 1;

/** See `prepare`: this is an event-loop stall, not a background wait. */
const BUSY_TIMEOUT_MS = 250;

const TABLES = ["bus_routes", "bus_messages", "bus_held", "bus_artifacts", "bus_deliveries"] as const;

// Columns for what is QUERIED, one JSON blob for what is only ever read back
// whole. `bus_routes` is filtered and ordered by `at`, so its fields are
// columns; the four scoped stores are always read for one session (or one
// project) at a time and folded in memory, so their rows carry the record as
// written and the Zod schema that already defines it stays the only definition
// of shape — a field added there needs no DDL here.
//
// `seq` is the insertion order, and for three of these it IS the semantics:
// a message log is a ring, a held queue goes out in the order it was written,
// and a delivery queue is FIFO per session.
const SCHEMA = `
CREATE TABLE IF NOT EXISTS bus_routes (
  contextId TEXT PRIMARY KEY,
  peerId    TEXT NOT NULL,
  projectId TEXT NOT NULL,
  at        INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_routes_project ON bus_routes (projectId);
CREATE INDEX IF NOT EXISTS bus_routes_at ON bus_routes (at);

CREATE TABLE IF NOT EXISTS bus_messages (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId TEXT NOT NULL,
  sessionId TEXT NOT NULL,
  entry     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_messages_session ON bus_messages (projectId, sessionId, seq);

CREATE TABLE IF NOT EXISTS bus_held (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId TEXT NOT NULL,
  sessionId TEXT NOT NULL,
  held      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_held_session ON bus_held (projectId, sessionId, seq);

CREATE TABLE IF NOT EXISTS bus_artifacts (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId  TEXT NOT NULL,
  sessionId  TEXT NOT NULL,
  record     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_artifacts_session ON bus_artifacts (projectId, sessionId, seq);

CREATE TABLE IF NOT EXISTS bus_deliveries (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId TEXT NOT NULL,
  line      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_deliveries_project ON bus_deliveries (projectId, seq);
`;

/** Said once per abDir per process. A store operation runs on every message, so
 *  an unreachable database would otherwise write the same line thousands of
 *  times and bury the first one, which is the only one that carries the cause. */
const announced = new Set<string>();

/** The machine-level session-bus root. Every bus record on this machine lives
 *  in one file here, keyed by project — never in a directory named after one.
 *  A carrier route is looked up by context id, which may name a session in any
 *  project the machine has open, so no project's directory could hold it; the
 *  rest followed when a reclaim narrower than an `rm -rf` was needed. */
export function sessionBusMachineDir(abDir: string): string {
  return join(abDir, "session-bus");
}

export function busDbPath(abDir: string): string {
  return join(sessionBusMachineDir(abDir), "bus.db");
}

function prepare(db: Database): void {
  // WAL so a reader (another host on the same ANTGRID_DIR, or this process's
  // own next operation) never blocks a writer.
  db.exec("PRAGMA journal_mode = WAL");
  // Not the codex reader's 0 — that one must not wait on another PRODUCT's
  // write lock, where this one waits on our own sibling holding it for a single
  // row. But bun:sqlite is synchronous, so this wait is the event loop's: every
  // terminal on the machine stops for the duration. The bound is therefore set
  // by what a user could feel, not by how long a lock could plausibly be held,
  // and losing the write costs a relearned route or a redelivered message.
  db.exec(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
  const found = (db.query("PRAGMA user_version").get() as { user_version?: number } | null)?.user_version ?? 0;
  if (found !== 0 && found !== BUS_DB_VERSION) {
    log.warn("session-bus: database is version %d, this bridge writes %d — dropping it", found, BUS_DB_VERSION);
    for (const table of TABLES) db.exec(`DROP TABLE IF EXISTS ${table}`);
  }
  db.exec(SCHEMA);
  if (found !== BUS_DB_VERSION) db.exec(`PRAGMA user_version = ${BUS_DB_VERSION}`);
}

/**
 * Run [fn] against the bus database, and answer [fallback] if it cannot.
 *
 * The fallback is not a convenience: every caller folds its store from
 * whatever comes back and has no throw-shaped path to put a database error on.
 * The empty store is the answer they are all built around; the announcement
 * (see the module header) is what keeps that from being silent.
 */
export function withBusDb<T>(abDir: string, fn: (db: Database) => T, fallback: T): T {
  try {
    return run(abDir, fn);
  } catch (err) {
    if (recoverIfCorrupt(abDir, err)) {
      try {
        return run(abDir, fn);
      } catch (second) {
        announceOnce(abDir, second);
        return fallback;
      }
    }
    announceOnce(abDir, err);
    return fallback;
  }
}

/**
 * Run [fn] against the bus database, and say so when it could not.
 *
 * For the operations `withBusDb`'s contract is wrong for: a DELETE, or a write
 * whose caller answers for it. An empty store is a truthful answer to a read
 * and to a save that the next message event rewrites anyway; for these two
 * there is no next event and no empty-store reading of the failure — it simply
 * did not happen, and something is about to report success on its behalf.
 *
 * Said EVERY time rather than once per abDir: these run on a delete or a
 * publish, not on every message, and each one names a different thing that was
 * lost.
 */
export function tryBusDb(abDir: string, what: string, fn: (db: Database) => void): boolean {
  try {
    run(abDir, fn);
    return true;
  } catch (err) {
    if (recoverIfCorrupt(abDir, err)) {
      try {
        run(abDir, fn);
        return true;
      } catch { /* fall through to the report below */ }
    }
    log.warn({ err }, `session-bus: ${what} — the bus database refused, so it did not happen`);
    return false;
  }
}

function run<T>(abDir: string, fn: (db: Database) => T): T {
  let db: Database | null = null;
  try {
    const dir = sessionBusMachineDir(abDir);
    // 0700/0600, the mode every durable store under the state dir is written
    // with (`discovery.ts`, `handler/session-store.ts`, `host-discovery.ts`).
    // One file now holds every message body, held frame, rendered delivery line
    // and peer relay slot id on the machine, so it is the LAST of them that may
    // be left at the umask default. SQLite gives `-wal` and `-shm` the mode of
    // the database file, so this has to land before the first write, not after.
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const path = join(dir, "bus.db");
    db = new Database(path, { create: true });
    restrict(path);
    prepare(db);
    return fn(db);
  } finally {
    try { db?.close(); } catch { /* a close that fails has nothing left to protect */ }
  }
}

function restrict(path: string): void {
  if (process.platform === "win32") return;
  try { chmodSync(path, 0o600); } catch { /* best effort, as everywhere else */ }
}

function announceOnce(abDir: string, err: unknown): void {
  if (announced.has(abDir)) return;
  announced.add(abDir);
  log.warn({ err }, `session-bus: cannot use ${busDbPath(abDir)} — bus state is not durable this run`);
}

/**
 * Move a database this build cannot read at all out of the way, so the next
 * call builds a fresh one.
 *
 * Only for CORRUPTION, never for a lock we lost or a permission we lack: those
 * heal on their own and moving the file would throw away good rows. A corrupt
 * one heals never — every store on the machine is in it, so one truncated write
 * from a power cut would otherwise cost this abDir its routes, its held
 * messages, its logs, its artifact handles and its delivery queue for the life
 * of the install. The JSON stores this replaced recovered on their next write
 * without anyone deciding they should; taking that away silently is the part
 * that had to be answered rather than the corruption itself.
 *
 * Kept, not deleted, because a database this reached is the only evidence of
 * whatever produced it.
 */
function recoverIfCorrupt(abDir: string, err: unknown): boolean {
  const code = (err as { code?: string } | null)?.code ?? "";
  const message = err instanceof Error ? err.message : String(err);
  const corrupt =
    code === "SQLITE_NOTADB" ||
    code === "SQLITE_CORRUPT" ||
    /not a database|disk image is malformed/i.test(message);
  if (!corrupt) return false;
  const path = busDbPath(abDir);
  try {
    for (const suffix of ["-wal", "-shm"]) rmSync(`${path}${suffix}`, { force: true });
    renameSync(path, `${path}.corrupt`);
  } catch (moveErr) {
    log.warn({ err: moveErr }, `session-bus: ${path} is corrupt and could not be moved aside`);
    return false;
  }
  log.warn(`session-bus: ${path} was corrupt — kept as bus.db.corrupt, starting a new one`);
  return true;
}

/** One store's rows: a session's, or — for the delivery queue, which is owned
 *  by a project rather than by any session in it — a project's. */
export interface BusScope {
  projectId: string;
  sessionId?: string;
}

function scopeWhere(scope: BusScope): { clause: string; params: string[] } {
  return scope.sessionId === undefined
    ? { clause: "projectId = ?", params: [scope.projectId] }
    : { clause: "projectId = ? AND sessionId = ?", params: [scope.projectId, scope.sessionId] };
}

// `table` and `column` are module constants at every call site, never anything a
// peer or an agent can name — which is what makes interpolating them into the
// SQL below safe. Every VALUE is bound.

/**
 * One scope's records, newest [cap] of them, OLDEST FIRST.
 *
 * Oldest first because for all three callers the order is the semantics, not
 * presentation: a message log is a ring, a held queue goes out in the order it
 * was written, and a delivery queue is FIFO. Newest [cap] because the cap keeps
 * the recent ones — a reader that took the oldest would pin a session to
 * whatever it said first and never show what it is saying now.
 *
 * A row that does not validate is skipped ALONE. A store that answered one bad
 * record by emptying itself would cost a session its whole log for one row.
 */
export function readRecords<T>(db: Database, table: string, column: string, scope: BusScope, cap: number, schema: z.ZodType<T>): T[] {
  const { clause, params } = scopeWhere(scope);
  const rows = db
    .query(`SELECT ${column} AS record FROM ${table} WHERE ${clause} ORDER BY seq DESC LIMIT ?`)
    .all(...params, cap) as { record: string }[];
  const out: T[] = [];
  for (const row of rows.reverse()) {
    let raw: unknown;
    try { raw = JSON.parse(row.record); } catch { continue; }
    const parsed = schema.safeParse(raw);
    if (parsed.success) out.push(parsed.data);
  }
  return out;
}

/**
 * Make one scope's rows exactly [records], in that order.
 *
 * Every caller holds its store as one immutable fold and hands it over entire,
 * so the CONTRACT is a whole-scope replace. What it does is write the
 * difference: the rows already there are aligned against [records], and only
 * the ones that must go and the ones that are new are touched. An append at the
 * cap — the shape every one of these stores actually has, message after message
 * — is then one DELETE and one INSERT rather than a few hundred of each. At the
 * message log's cap with full-size parts that is the difference between ~17 ms
 * and ~7 ms, and bun:sqlite is synchronous, so it is the difference between two
 * event-loop stalls of that size on the loop serving every PTY on the machine.
 *
 * The alignment is the whole safety argument: it looks for the smallest number
 * of leading rows whose removal leaves the rest a PREFIX of [records], comparing
 * the stored text against what would be written. When no such alignment exists —
 * a record removed from the middle, a store rewritten wholesale, anything
 * unexpected at all — every row goes and every record is inserted. The fast path
 * cannot leave a stale row, because the only way to reach it is to have proved
 * row by row that the survivors are the ones wanted.
 *
 * One transaction either way, so a reader never sees the scope half-written.
 */
export function replaceRecords(db: Database, table: string, column: string, scope: BusScope, records: readonly unknown[]): void {
  const { clause, params } = scopeWhere(scope);
  const cols = scope.sessionId === undefined ? `projectId, ${column}` : `projectId, sessionId, ${column}`;
  const values = scope.sessionId === undefined ? "(?, ?)" : "(?, ?, ?)";
  const insert = db.query(`INSERT INTO ${table} (${cols}) VALUES ${values}`);
  const wanted = records.map((record) => JSON.stringify(record));

  db.transaction(() => {
    // Read INSIDE the transaction. A sibling host committing between the read
    // and the write would otherwise have this delete rows by a seq it no longer
    // owns and append a tail that is already there; from in here, WAL answers
    // the write-upgrade with a conflict instead, and a refused write is a state
    // this seam already has an answer for.
    const stored = db
      .query(`SELECT seq, ${column} AS record FROM ${table} WHERE ${clause} ORDER BY seq`)
      .all(...params) as { seq: number; record: string }[];
    const drop = leadingRowsToDrop(stored, wanted);
    if (drop === null) {
      db.query(`DELETE FROM ${table} WHERE ${clause}`).run(...params);
      for (const record of wanted) insert.run(...params, record);
      return;
    }
    const dropOne = db.query(`DELETE FROM ${table} WHERE seq = ?`);
    for (let i = 0; i < drop; i += 1) dropOne.run(stored[i]!.seq);
    for (let i = stored.length - drop; i < wanted.length; i += 1) insert.run(...params, wanted[i]!);
  })();
}

/** How many leading rows must go for the rest to be a prefix of [wanted], or
 *  null when nothing makes it one and the scope has to be rewritten. */
function leadingRowsToDrop(stored: readonly { record: string }[], wanted: readonly string[]): number | null {
  for (let drop = 0; drop <= stored.length; drop += 1) {
    const overlap = stored.length - drop;
    if (overlap > wanted.length) continue;
    let matches = true;
    for (let i = 0; i < overlap; i += 1) {
      if (stored[drop + i]!.record !== wanted[i]) { matches = false; break; }
    }
    if (matches) return drop;
  }
  return null;
}

/** Every row any of these tables holds for [scope]. The bytes an artifact
 *  points at are NOT here — they are still files, and still reclaimed by the
 *  directory delete in `store-fs.ts`. */
export function deleteScope(db: Database, scope: BusScope): void {
  const { clause, params } = scopeWhere(scope);
  db.transaction(() => {
    for (const table of TABLES) {
      // The delivery queue is per project and has no sessionId to narrow by, so
      // a session-scoped delete must not reach it: its lines belong to every
      // other session in the project too.
      if (table === "bus_routes") continue;
      if (table === "bus_deliveries" && scope.sessionId !== undefined) continue;
      db.query(`DELETE FROM ${table} WHERE ${clause}`).run(...params);
    }
    if (scope.sessionId === undefined) {
      db.query("DELETE FROM bus_routes WHERE projectId = ?").run(scope.projectId);
    }
  })();
}

/** Forget that this abDir's failure was already announced. For tests, which
 *  reuse one process across many temp dirs and would otherwise silence the
 *  second failure they meant to observe. */
export function resetBusDbAnnouncements(): void {
  announced.clear();
}
