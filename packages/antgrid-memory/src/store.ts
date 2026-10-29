import { Database, type Statement } from "bun:sqlite";
import { chmodSync, mkdirSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { join } from "node:path";
import { MemoryError } from "./contracts";

export class MemoryStore {
  readonly db: Database;
  readonly ownerId: string;
  private readonly statements = new Map<string, Statement>();
  searchReady = false;
  constructor(directory: string) {
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const path = join(directory, "memory.sqlite");
    this.db = new Database(path, { create: true, strict: true });
    try {
      if (process.platform !== "win32") chmodSync(path, 0o600);
      this.db.exec("PRAGMA busy_timeout=20; PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA secure_delete=ON;");
      const version = (this.query("PRAGMA user_version").get() as { user_version: number }).user_version;
      if (version > 2) throw new MemoryError("UNAVAILABLE", "Memory database was written by a newer version; upgrade Antgrid");
      if (version === 0) this.db.transaction(() => {
        this.db.exec(`
          CREATE TABLE profile (singleton INTEGER PRIMARY KEY CHECK(singleton=1), owner_id TEXT NOT NULL, enabled INTEGER NOT NULL DEFAULT 0, paused INTEGER NOT NULL DEFAULT 0, cleanup_pending INTEGER NOT NULL DEFAULT 0);
          CREATE TABLE project_settings (project_id TEXT PRIMARY KEY, paused INTEGER NOT NULL);
          CREATE TABLE records (
            id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, scope TEXT NOT NULL,
            project_id TEXT, task_id TEXT, checkout_id TEXT, memory_type TEXT NOT NULL,
            content TEXT NOT NULL, applicability TEXT, evidence TEXT NOT NULL, source TEXT NOT NULL,
            supersedes TEXT, superseded_by TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            match_hash TEXT NOT NULL
          );
          CREATE INDEX records_scope ON records(owner_id, project_id, task_id);
          CREATE INDEX records_duplicate ON records(match_hash);
          CREATE TABLE operations (
            binding TEXT NOT NULL, operation_key TEXT NOT NULL, payload_hash TEXT, match_hash TEXT,
            target_id TEXT, payload TEXT, record_id TEXT, outcome TEXT, origin_project_id TEXT, failure_code TEXT,
            state TEXT NOT NULL CHECK(state IN ('pending','resolved','suppressed')),
            PRIMARY KEY(binding,operation_key)
          );
          CREATE INDEX operation_record ON operations(record_id);
          CREATE INDEX operation_target ON operations(target_id);
          PRAGMA user_version=1;
        `);
        this.query("INSERT INTO profile(singleton,owner_id) VALUES(1,?)").run(crypto.randomUUID());
        this.createIndex();
      }).immediate();
      if (version < 2) this.db.transaction(() => {
        this.db.exec(`
          CREATE TABLE export_state (singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL CHECK(revision>=0), cursor_key TEXT NOT NULL);
          CREATE INDEX records_export ON records(owner_id,id);
          CREATE INDEX records_project_export ON records(owner_id,project_id,id);
          CREATE TRIGGER export_record_insert AFTER INSERT ON records BEGIN UPDATE export_state SET revision=revision+1 WHERE singleton=1; END;
          CREATE TRIGGER export_record_update AFTER UPDATE ON records BEGIN UPDATE export_state SET revision=revision+1 WHERE singleton=1; END;
          CREATE TRIGGER export_record_delete AFTER DELETE ON records BEGIN UPDATE export_state SET revision=revision+1 WHERE singleton=1; END;
          PRAGMA user_version=2;
        `);
        this.query("INSERT INTO export_state(singleton,revision,cursor_key) VALUES(1,0,?)").run(randomBytes(32).toString("hex"));
      }).immediate();
      const profile = this.query("SELECT owner_id FROM profile WHERE singleton=1").get() as { owner_id: string } | null;
      if (!profile?.owner_id) throw new MemoryError("UNAVAILABLE", "Memory profile identity is missing; preserve the database for recovery");
      this.ownerId = profile.owner_id;
      // Do not catch canonical corruption as an index failure and replace the store.
      for (const _row of this.query("SELECT id, content, applicability FROM records").iterate()) { /* Read without retaining the store in memory. */ }
      const exportState = this.query("SELECT revision,cursor_key FROM export_state WHERE singleton=1").get() as { revision: number; cursor_key: string } | null;
      if (!exportState || !Number.isSafeInteger(exportState.revision) || exportState.revision < 0 || !/^[a-f0-9]{64}$/.test(exportState.cursor_key)) {
        throw new MemoryError("UNAVAILABLE", "Memory export state is damaged; preserve the database for recovery");
      }
      try { this.checkIndex(); this.searchReady = true; }
      catch { try { this.repair(); } catch { this.searchReady = false; } }
    } catch (error) { this.close(); throw error; }
  }

  private createIndex(): void {
    this.db.exec(`
      CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED, content, applicability, tokenize='unicode61');
      INSERT INTO memory_fts(memory_fts,rank) VALUES('secure-delete',1);
      CREATE TRIGGER memory_insert AFTER INSERT ON records BEGIN
        INSERT INTO memory_fts(id,content,applicability) VALUES(new.id,new.content,new.applicability);
      END;
      CREATE TRIGGER memory_delete AFTER DELETE ON records BEGIN DELETE FROM memory_fts WHERE id=old.id; END;
      CREATE TRIGGER memory_update AFTER UPDATE OF content,applicability ON records BEGIN
        DELETE FROM memory_fts WHERE id=old.id;
        INSERT INTO memory_fts(id,content,applicability) VALUES(new.id,new.content,new.applicability);
      END;
    `);
  }

  checkIndex(): void {
    this.db.exec("INSERT INTO memory_fts(memory_fts) VALUES('integrity-check')");
    const row = this.query(`SELECT
      (SELECT count(*) FROM records) != (SELECT count(*) FROM memory_fts)
      OR EXISTS(SELECT 1 FROM records r LEFT JOIN memory_fts f ON f.id=r.id
        WHERE f.id IS NULL OR f.content IS NOT r.content OR f.applicability IS NOT r.applicability) AS damaged`).get() as { damaged: number };
    if (row.damaged) throw new MemoryError("SEARCH_UNAVAILABLE", "Memory search index requires rebuilding");
  }

  repair(): void {
    this.searchReady = false;
    this.db.transaction(() => {
      this.db.exec("DROP TRIGGER IF EXISTS memory_insert; DROP TRIGGER IF EXISTS memory_delete; DROP TRIGGER IF EXISTS memory_update; DROP TABLE IF EXISTS memory_fts;");
      this.createIndex();
      this.db.exec("INSERT INTO memory_fts(id,content,applicability) SELECT id,content,applicability FROM records");
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
