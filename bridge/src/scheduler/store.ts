import { Database } from "bun:sqlite";
import { chmodSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ScheduleSchema, SchedulerRunSchema, isActiveRun, type Schedule, type SchedulerRun } from "./models";

// Before chat schedules had an explicit mode they inherited the last-used chat config, so an existing one may be running
// hands-free only because of that. Marked rows are resolved against it once at the next start (see the service).
// Raw JSON, not ScheduleSchema, so a row an older bridge wrote cannot make the migration itself fail.
function markChatModeCarryOver(db: Database): void {
  const rows = db.query("SELECT id,record FROM schedules").all() as { id: string; record: string }[];
  for (const row of rows) {
    const record = JSON.parse(row.record) as Record<string, unknown>;
    if (record.deletedAt !== undefined || record.mode !== "chat" || record.approvalPolicy === "bypass") continue;
    db.query("UPDATE schedules SET record=? WHERE id=?").run(JSON.stringify({ ...record, chatModeCarryOver: true }), row.id);
  }
}

export class SchedulerStore {
  readonly path: string;
  private readonly owner = randomUUID();
  private closed = false;

  constructor(abDir: string) {
    const dir = join(abDir, "scheduler");
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    this.path = join(dir, "scheduler.db");
    const db = new Database(this.path, { create: true, strict: true });
    try {
      db.exec("PRAGMA busy_timeout = 250; PRAGMA journal_mode = WAL;");
      db.transaction(() => {
        const version = (db.query("PRAGMA user_version").get() as { user_version: number }).user_version;
        // Each bump adds record fields (v2 a run trigger, v3 one-off and provenance fields) that an older bridge's
        // closed schemas would fail to parse, so the bump makes it refuse the database up front instead.
        if (version < 0 || version > 3) throw new Error("Scheduler database requires a newer bridge");
        db.exec(`CREATE TABLE IF NOT EXISTS scheduler_owner (id INTEGER PRIMARY KEY CHECK(id=1),pid INTEGER NOT NULL,token TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS schedules (id TEXT PRIMARY KEY, record TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, scheduleId TEXT NOT NULL,
            claimKey TEXT UNIQUE, active INTEGER NOT NULL, startedAt INTEGER NOT NULL, record TEXT NOT NULL);
          CREATE INDEX IF NOT EXISTS runs_history ON runs (scheduleId, startedAt);
          PRAGMA user_version = 3;`);
        if (version < 3) markChatModeCarryOver(db);
        const owner = db.query("SELECT pid,token FROM scheduler_owner WHERE id=1").get() as { pid: number; token: string } | null;
        if (owner) {
          if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw new Error("Scheduler owner record is invalid");
          try { process.kill(owner.pid, 0); throw new Error("Another desktop host owns this scheduler state directory"); }
          catch (live) { if ((live as NodeJS.ErrnoException).code !== "ESRCH") throw live; }
        }
        db.query("INSERT INTO scheduler_owner(id,pid,token) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET pid=excluded.pid,token=excluded.token")
          .run(process.pid, this.owner);
      }).immediate();
    } finally { db.close(); }
  }

  private withDb<T>(fn: (db: Database) => T): T {
    if (this.closed) throw new Error("Scheduler is closed");
    const db = new Database(this.path, { create: false, strict: true });
    try {
      if (process.platform !== "win32") chmodSync(this.path, 0o600);
      db.exec("PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 250; PRAGMA synchronous = FULL;");
      const owner = db.query("SELECT token FROM scheduler_owner WHERE id=1").get() as { token: string } | null;
      if (owner?.token !== this.owner) throw new Error("Scheduler ownership was lost");
      return fn(db);
    } finally { db.close(); }
  }

  private readSchedules(db: Database): Schedule[] {
    return (db.query("SELECT record FROM schedules").all() as { record: string }[])
      .map((row) => ScheduleSchema.parse(JSON.parse(row.record)));
  }
  private readRuns(db: Database): SchedulerRun[] {
    return (db.query("SELECT record FROM runs ORDER BY startedAt DESC, rowid DESC").all() as { record: string }[])
      .map((row) => SchedulerRunSchema.parse(JSON.parse(row.record)));
  }
  schedules(includeDeleted = false): Schedule[] {
    return this.withDb((db) => this.readSchedules(db).filter((s) => includeDeleted || s.deletedAt === undefined));
  }
  runs(scheduleId?: string): SchedulerRun[] {
    return this.withDb((db) => this.readRuns(db).filter((run) => !scheduleId || run.scheduleId === scheduleId));
  }
  saveSchedule(schedule: Schedule): void {
    this.withDb((db) => this.writeSchedule(db, schedule));
  }
  private writeSchedule(db: Database, schedule: Schedule): void {
    db.query("INSERT INTO schedules(id,record) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET record=excluded.record")
      .run(schedule.id, JSON.stringify(ScheduleSchema.parse(schedule)));
  }
  private writeRun(db: Database, run: SchedulerRun, claimKey?: string): void {
    db.query(`INSERT INTO runs(id,scheduleId,claimKey,active,startedAt,record) VALUES(?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET active=excluded.active,record=excluded.record`)
      .run(run.id, run.scheduleId, claimKey ?? null, isActiveRun(run) ? 1 : 0, run.startedAt, JSON.stringify(SchedulerRunSchema.parse(run)));
  }

  /**
   * `missed` is a consolidated terminal record written in the same transaction, under its own claim key.
   *
   * `oneOff` claims the single occurrence of a one-off schedule: the run and the schedule's fired marker commit
   * together, so a restart can neither lose the occurrence nor fire it twice. If any run of the schedule is active it
   * consumes nothing (no run, claim key or fired marker) and returns null, because a one-off has no later occurrence
   * to absorb an overlap skip; it only marks the schedule `deferredAt`, so the claim after the active run ends runs
   * the occurrence rather than writing it off as missed.
   */
  claim(schedule: Schedule, run: SchedulerRun, nextOccurrence?: number, missed?: SchedulerRun, oneOff = false): SchedulerRun | null {
    return this.withDb((db) => db.transaction(() => {
      const current = this.readSchedules(db).find((s) => s.id === schedule.id);
      if (!current || current.deletedAt !== undefined) return null;
      if (oneOff) {
        // An edit between the tick's read and this claim (a new time, or already fired) must win.
        if (current.firedRunId !== undefined || current.runAt !== schedule.runAt) return null;
        if (this.readRuns(db).some((r) => r.scheduleId === schedule.id && isActiveRun(r))) {
          if (current.deferredAt === undefined) this.writeSchedule(db, { ...current, deferredAt: run.startedAt });
          return null;
        }
      }
      const keyOf = (r: SchedulerRun) => r.trigger === "manual" ? undefined : `${schedule.id}:${r.occurrenceAt}`;
      const key = keyOf(run);
      if (key && db.query("SELECT id FROM runs WHERE claimKey=?").get(key)) return null;
      if (run.status === "preparing") {
        const active = this.readRuns(db).filter(isActiveRun);
        if (active.some((r) => r.scheduleId === schedule.id)) {
          run = { ...run, status: "skipped", reason: "An occurrence of this schedule is still active", finishedAt: run.startedAt };
        }
      }
      if (oneOff) {
        const { deferredAt: _deferred, ...rest } = current;
        this.writeSchedule(db, { ...rest, firedRunId: run.id, firedAt: run.startedAt });
      }
      else if (nextOccurrence !== undefined) this.writeSchedule(db, { ...current, nextOccurrence });
      const missedKey = missed && keyOf(missed);
      if (missed && !(missedKey && db.query("SELECT id FROM runs WHERE claimKey=?").get(missedKey))) this.writeRun(db, missed, missedKey);
      this.writeRun(db, run, key);
      this.prune(db, run.scheduleId);
      return run;
    }).immediate());
  }
  updateRun(id: string, update: (run: SchedulerRun) => SchedulerRun): SchedulerRun {
    return this.withDb((db) => db.transaction(() => {
      const run = this.readRuns(db).find((r) => r.id === id);
      if (!run) throw new Error("Run no longer exists");
      const next = update(run);
      this.writeRun(db, next);
      this.prune(db, run.scheduleId);
      return next;
    }).immediate());
  }
  /**
   * Gives a one-off back to the scheduler when its settings changed while it was being prepared: the run ends as
   * skipped, its claim key is released and the fired marker is cleared (only if it still names this run), so the next
   * tick claims the occurrence again with the new settings.
   *
   * A run that already ended (stopped by the user, or failed) is left alone and false is returned: that occurrence
   * was spent, and handing it back would run a one-off the user stopped.
   */
  rearm(id: string, reason: string, finishedAt: number): boolean {
    return this.withDb((db) => db.transaction(() => {
      const run = this.readRuns(db).find((r) => r.id === id);
      if (!run) throw new Error("Run no longer exists");
      if (!isActiveRun(run)) return false;
      this.writeRun(db, { ...run, status: "skipped", reason, finishedAt });
      db.query("UPDATE runs SET claimKey=NULL WHERE id=?").run(id);
      const schedule = this.readSchedules(db).find((s) => s.id === run.scheduleId);
      if (schedule?.firedRunId === id) {
        const { firedRunId: _run, firedAt: _at, ...rest } = schedule;
        this.writeSchedule(db, { ...rest, deferredAt: schedule.deferredAt ?? finishedAt });
      }
      return true;
    }).immediate());
  }
  bind(id: string, identity: { sessionId: string; runtimeGeneration: string; checkoutId?: string }): void {
    this.withDb((db) => db.transaction(() => {
      const run = this.readRuns(db).find((r) => r.id === id);
      if (!run || !isActiveRun(run)) throw new Error("Run is no longer active");
      const schedule = this.readSchedules(db).find((s) => s.id === run.scheduleId);
      if (!schedule) throw new Error("Schedule no longer exists");
      this.writeRun(db, { ...run, ...identity });
      this.writeSchedule(db, { ...schedule, workspaceCreated: true, ...(identity.checkoutId ? { checkoutId: identity.checkoutId } : {}) });
    }).immediate());
  }
  private prune(db: Database, scheduleId: string): void {
    db.query(`DELETE FROM runs WHERE id IN (SELECT id FROM runs WHERE scheduleId=? AND active=0
      ORDER BY startedAt DESC,rowid DESC LIMIT -1 OFFSET 500)`).run(scheduleId);
  }
  close(): void {
    if (this.closed) return;
    try { this.withDb((db) => db.query("DELETE FROM scheduler_owner WHERE id=1 AND token=?").run(this.owner)); }
    catch { /* A missing or failed store must remain failed, including during shutdown. */ }
    this.closed = true;
  }
}
