import { Database, type Statement } from "bun:sqlite";
import { chmodSync, existsSync, mkdirSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { MemoryError } from "./contracts";

const SCHEMA_VERSION = 1;

export const MEMORY_DATABASE = "memory.sqlite";

/**
 * Reads the profile's enabled flag without creating, upgrading or repairing the
 * store. Undefined when there is no readable store.
 */
export function readMemoryEnabled(directory: string): boolean | undefined {
  const path = join(directory, MEMORY_DATABASE);
  if (!existsSync(path)) return undefined;
  let db: Database | undefined;
  try {
    db = new Database(path, { readonly: true });
    const row = db.query("SELECT enabled FROM profile WHERE singleton=1").get() as { enabled: number } | null;
    return row ? !!row.enabled : undefined;
  } catch { return undefined; }
  finally { db?.close(); }
}

export class MemoryStore {
  readonly db: Database;
  readonly ownerId: string;
  private readonly statements = new Map<string, Statement>();
  searchReady = false;
  constructor(directory: string) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const path = join(directory, MEMORY_DATABASE);
    this.db = new Database(path, { create: true, strict: true });
    try {
      if (process.platform !== "win32") chmodSync(path, 0o600);
      this.db.exec("PRAGMA busy_timeout=20; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;");
      const version = () => (this.query("PRAGMA user_version").get() as { user_version: number }).user_version;
      if (version() > SCHEMA_VERSION) throw new MemoryError("UNAVAILABLE", "Memory database was written by a newer version; upgrade Antgrid");
      // Re-read under the write lock: another connection may have created the
      // store while this one waited for it.
      if (version() === 0) this.db.transaction(() => { if (version() === 0) this.create(); }).immediate();
      const profile = this.query("SELECT owner_id FROM profile WHERE singleton=1").get() as { owner_id: string } | null;
      if (!profile?.owner_id) throw new MemoryError("UNAVAILABLE", "Memory profile identity is missing; preserve the database for recovery");
      this.ownerId = profile.owner_id;
      const exportState = this.query("SELECT cursor_key FROM export_state WHERE singleton=1").get() as { cursor_key: string } | null;
      if (!exportState || !/^[a-f0-9]{64}$/.test(exportState.cursor_key)) {
        throw new MemoryError("UNAVAILABLE", "Memory export state is damaged; preserve the database for recovery");
      }
      try { this.checkIndex(); this.searchReady = true; }
      catch {
        // A passing checkIndex has read every canonical row; a failing one may
        // have stopped early. Canonical corruption thrown here fails the open
        // rather than being treated as an index failure and replacing the store.
        for (const _row of this.query("SELECT id, content, applicability FROM records").iterate()) { /* Read without retaining the store in memory. */ }
        try { this.repair(); } catch { this.searchReady = false; }
      }
    } catch (error) { this.close(); throw error; }
  }

  private create(): void {
    this.db.exec(`
      CREATE TABLE profile (singleton INTEGER PRIMARY KEY CHECK(singleton=1), owner_id TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, paused INTEGER NOT NULL DEFAULT 0, cleanup_pending INTEGER NOT NULL DEFAULT 0);
      CREATE TABLE project_settings (project_id TEXT PRIMARY KEY, paused INTEGER NOT NULL);
      CREATE TABLE operations (
        binding TEXT NOT NULL, operation_key TEXT NOT NULL, payload_hash TEXT, match_hash TEXT,
        target_id TEXT, payload TEXT, record_id TEXT, outcome TEXT, origin_project_id TEXT, failure_code TEXT,
        state TEXT NOT NULL CHECK(state IN ('pending','resolved','suppressed')),
        PRIMARY KEY(binding,operation_key)
      );
      CREATE INDEX operation_record ON operations(record_id);
      CREATE INDEX operation_target ON operations(target_id);
      CREATE INDEX operation_match ON operations(match_hash);
      CREATE INDEX operation_pending ON operations(origin_project_id) WHERE state='pending';
      CREATE INDEX operation_failed ON operations(origin_project_id) WHERE failure_code IS NOT NULL;
      CREATE TABLE export_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), cursor_key TEXT NOT NULL);
      CREATE TABLE export_revisions (context TEXT PRIMARY KEY, revision INTEGER NOT NULL CHECK(revision>=0));
      -- seq is both the FTS rowid and an export's snapshot bound. AUTOINCREMENT
      -- keeps a deleted maximum from being reissued to a row that would then
      -- fall inside an export already in progress.
      CREATE TABLE records (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        id TEXT NOT NULL UNIQUE, owner_id TEXT NOT NULL, scope TEXT NOT NULL,
        project_id TEXT NOT NULL, task_id TEXT, checkout_id TEXT, memory_type TEXT NOT NULL,
        content TEXT NOT NULL, applicability TEXT, evidence TEXT NOT NULL, source TEXT NOT NULL,
        supersedes TEXT, superseded_by TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
        match_hash TEXT NOT NULL
      );
    `);
    this.query("INSERT INTO profile(singleton,owner_id) VALUES(1,?)").run(crypto.randomUUID());
    this.query("INSERT INTO export_state(singleton,cursor_key) VALUES(1,?)").run(randomBytes(32).toString("hex"));
    // An export is invalidated only by a change inside its own context: '*' for
    // the machine, the project id for a project export.
    // Inserts are excluded by the export's sequence bound instead.
    const bump = (row: "old" | "new") => `INSERT INTO export_revisions VALUES('*',1),(${row}.project_id,1)
      ON CONFLICT(context) DO UPDATE SET revision=revision+1;`;
    this.db.exec(`
      CREATE INDEX records_scope ON records(owner_id, project_id, task_id);
      CREATE INDEX records_duplicate ON records(match_hash);
      CREATE INDEX records_supersedes ON records(supersedes);
      CREATE INDEX records_export ON records(owner_id,id);
      CREATE INDEX records_project_export ON records(owner_id,project_id,id);
      CREATE TRIGGER export_record_update AFTER UPDATE ON records BEGIN ${bump("old")} ${bump("new")} END;
      CREATE TRIGGER export_record_delete AFTER DELETE ON records BEGIN ${bump("old")} END;
    `);
    this.createIndex();
    this.db.exec(`PRAGMA user_version=${SCHEMA_VERSION}`);
  }

  private createIndex(): void {
    this.db.exec(`
      CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED, content, applicability, tokenize='unicode61');
      INSERT INTO memory_fts(memory_fts,rank) VALUES('secure-delete',1);
      CREATE TRIGGER memory_insert AFTER INSERT ON records BEGIN
        INSERT INTO memory_fts(rowid,id,content,applicability) VALUES(new.seq,new.id,new.content,new.applicability);
      END;
      CREATE TRIGGER memory_delete AFTER DELETE ON records BEGIN DELETE FROM memory_fts WHERE rowid=old.seq; END;
      CREATE TRIGGER memory_update AFTER UPDATE OF content,applicability ON records BEGIN
        DELETE FROM memory_fts WHERE rowid=old.seq;
        INSERT INTO memory_fts(rowid,id,content,applicability) VALUES(new.seq,new.id,new.content,new.applicability);
      END;
    `);
  }

  private fillIndex(): void {
    this.db.exec("INSERT INTO memory_fts(rowid,id,content,applicability) SELECT seq,id,content,applicability FROM records");
  }

  /**
   * Runs on every open, so it is linear: FTS rowids are unique, and equal counts
   * plus one rowid lookup per record prove the index mirrors the table. FTS5's
   * own structural check reads the whole index and is left to repair.
   */
  checkIndex(): void {
    const row = this.query(`SELECT
      (SELECT count(*) FROM records) != (SELECT count(*) FROM memory_fts)
      OR EXISTS(SELECT 1 FROM records r LEFT JOIN memory_fts f ON f.rowid=r.seq
        WHERE f.rowid IS NULL OR f.id IS NOT r.id OR f.content IS NOT r.content OR f.applicability IS NOT r.applicability) AS damaged`).get() as { damaged: number };
    if (row.damaged) throw new MemoryError("SEARCH_UNAVAILABLE", "Memory search index requires rebuilding");
  }

  repair(): void {
    this.searchReady = false;
    this.db.transaction(() => {
      this.db.exec("DROP TRIGGER IF EXISTS memory_insert; DROP TRIGGER IF EXISTS memory_delete; DROP TRIGGER IF EXISTS memory_update; DROP TABLE IF EXISTS memory_fts;");
      this.createIndex();
      this.fillIndex();
      this.db.exec("INSERT INTO memory_fts(memory_fts) VALUES('integrity-check')");
      this.checkIndex();
    }).immediate();
    this.searchReady = true;
  }
  query(sql: string): Statement {
    let statement = this.statements.get(sql);
    if (statement) return statement;
    statement = this.db.prepare(sql);
    this.statements.set(sql, statement);
    return statement;
  }
  close(): void {
    // Relying on GC for evicted Bun query statements leaves Windows database
    // handles open after close; this store owns every prepared statement.
    for (const statement of this.statements.values()) statement.finalize();
    this.statements.clear();
    this.db.close(true);
  }
}
