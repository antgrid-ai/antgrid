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
// Nothing here throws. A caller that cannot reach the database gets the same
// answer it got when a JSON file failed to parse — the EMPTY store — with one
// difference that is the point: the failure is SAID, once per process, with the
// error that caused it. `readStoreFile` said nothing at all, and for the
// machine-level routes that meant every project's carrier bindings vanishing
// with no line anywhere to name why.

import { Database } from "bun:sqlite";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { logger } from "../logger";
import { sessionBusMachineDir } from "./store-fs";

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
  at        INTEGER NOT NULL,
  direction TEXT NOT NULL,
  peer      TEXT NOT NULL,
  envelope  TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_messages_session ON bus_messages (projectId, sessionId, seq);

CREATE TABLE IF NOT EXISTS bus_held (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId TEXT NOT NULL,
  sessionId TEXT NOT NULL,
  messageId TEXT NOT NULL,
  contextId TEXT NOT NULL,
  role      TEXT NOT NULL,
  recipient TEXT NOT NULL,
  frame     TEXT NOT NULL,
  heldAt    INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_held_session ON bus_held (projectId, sessionId, seq);

CREATE TABLE IF NOT EXISTS bus_artifacts (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId  TEXT NOT NULL,
  sessionId  TEXT NOT NULL,
  artifactId TEXT NOT NULL,
  record     TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_artifacts_session ON bus_artifacts (projectId, sessionId, seq);

CREATE TABLE IF NOT EXISTS bus_deliveries (
  seq       INTEGER PRIMARY KEY AUTOINCREMENT,
  projectId TEXT NOT NULL,
  sessionId TEXT NOT NULL,
  lineId    TEXT NOT NULL,
  line      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS bus_deliveries_project ON bus_deliveries (projectId, seq);
`;

/** Said once per abDir per process. A store operation runs on every message, so
 *  an unreachable database would otherwise write the same line thousands of
 *  times and bury the first one, which is the only one that carries the cause. */
const announced = new Set<string>();

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
 * The fallback is not a convenience: every caller here replaced a JSON store
 * whose read answered EMPTY on any failure at all, and none of them has a
 * throw-shaped path to put a database error on. What changes is that the
 * failure is now announced (see the module header).
 */
export function withBusDb<T>(abDir: string, fn: (db: Database) => T, fallback: T): T {
  let db: Database | null = null;
  try {
    const dir = sessionBusMachineDir(abDir);
    mkdirSync(dir, { recursive: true });
    db = new Database(join(dir, "bus.db"), { create: true });
    prepare(db);
    return fn(db);
  } catch (err) {
    if (!announced.has(abDir)) {
      announced.add(abDir);
      log.warn({ err }, `session-bus: cannot use ${busDbPath(abDir)} — bus state is not durable this run`);
    }
    return fallback;
  } finally {
    try { db?.close(); } catch { /* a close that fails has nothing left to protect */ }
  }
}

/** Forget that this abDir's failure was already announced. For tests, which
 *  reuse one process across many temp dirs and would otherwise silence the
 *  second failure they meant to observe. */
export function resetBusDbAnnouncements(): void {
  announced.clear();
}
