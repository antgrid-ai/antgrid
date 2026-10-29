import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import {
  LIMITS, TASK_EXPIRY_MS, MemoryError, MemoryRequestSchema, MemoryRecordSchema, bytes, redactSave,
  type MemoryContext, type MemoryRecord, type MemoryRequest, type MemorySave,
} from "./contracts";
import { ftsQuery, searchResponse } from "./search";
import { MemoryStore } from "./store";

type ContextSource = MemoryContext | (() => MemoryContext);
type Row = {
  id: string; owner_id: string; scope: MemoryRecord["scope"]; project_id: string | null;
  task_id: string | null; checkout_id: string | null; memory_type: MemoryRecord["memory_type"];
  content: string; applicability: string | null; evidence: string; source: string;
  supersedes: string | null; superseded_by: string | null; created_at: number; updated_at: number; match_hash: string;
};
type Operation = {
  binding: string; operation_key: string; payload_hash: string | null; match_hash: string | null;
  target_id: string | null; payload: string | null; record_id: string | null;
  outcome: "saved" | "already_present" | null; state: "pending" | "resolved" | "suppressed";
  origin_project_id: string | null;
  failure_code: string | null;
};
type Placement = { scope: MemoryRecord["scope"]; project_id: string | null; task_id: string | null; checkout_id: string | null };
type SaveResult = { operation_key: string; id: string; outcome: "saved" | "already_present"; lifecycle: MemoryRecord["lifecycle"] };
const hash = (value: unknown): string => createHash("sha256").update(JSON.stringify(value)).digest("hex");
const isBusy = (error: unknown): boolean => !!error && typeof error === "object" && "code" in error && /SQLITE_(BUSY|LOCKED)/.test(String(error.code));
const ExportCursorSchema = z.object({
  version: z.literal(1), binding: z.string().regex(/^[a-f0-9]{64}$/), revision: z.number().int().nonnegative(),
  last_id: z.string().min(1).max(256), exported_at: z.number().int().nonnegative(),
}).strict();
type ExportCursor = z.infer<typeof ExportCursorSchema>;
function signCursor(cursor: ExportCursor, key: string): string {
  const payload = Buffer.from(JSON.stringify(cursor)).toString("base64url");
  return `${payload}.${createHmac("sha256", Buffer.from(key, "hex")).update(payload).digest("hex")}`;
}
function readCursor(cursor: string, key: string): ExportCursor {
  const parts = /^([A-Za-z0-9_-]+)\.([a-f0-9]{64})$/.exec(cursor);
  if (!parts) throw new MemoryError("INVALID_ARGUMENT", "Invalid memory export cursor");
  const payload = parts[1]!;
  const signature = Buffer.from(parts[2]!, "hex");
  const expected = createHmac("sha256", Buffer.from(key, "hex")).update(payload).digest();
  if (!timingSafeEqual(signature, expected)) throw new MemoryError("INVALID_ARGUMENT", "Invalid memory export cursor");
  try { return ExportCursorSchema.parse(JSON.parse(Buffer.from(payload, "base64url").toString("utf8"))); }
  catch { throw new MemoryError("INVALID_ARGUMENT", "Invalid memory export cursor"); }
}

export class MemoryService {
  private readonly store: MemoryStore;
  private readonly now: () => number;
  private queue: Promise<unknown> = Promise.resolve();
  private closed = false;
  readonly ownerId: string;

  constructor(options: { directory: string; now?: () => number }) {
    this.store = new MemoryStore(options.directory);
    this.ownerId = this.store.ownerId;
    this.now = options.now ?? Date.now;
  }
  close(): void { this.closed = true; this.store.close(); }

  execute(context: ContextSource, raw: unknown, options: { maxAttempts?: 1 | 3 } = {}): Promise<Record<string, unknown>> {
    let request: MemoryRequest;
    try { request = MemoryRequestSchema.parse(raw); }
    catch (error) { return Promise.reject(this.validation(error)); }
    const deadline = performance.now() + 2000;
    const task = this.queue.then(async () => {
      for (let attempt = 0; attempt < (options.maxAttempts ?? 3); attempt++) {
        const ctx = this.context(context);
        if (performance.now() >= deadline) throw new MemoryError("BUSY", "Memory request exceeded its queue deadline; retry the same operation key");
        try {
          if (request.op === "recover") return await this.recover(context, deadline);
          return this.dispatch(ctx, request);
        } catch (error) {
          if (isBusy(error)) {
            if (attempt + 1 >= (options.maxAttempts ?? 3) || performance.now() + 80 >= deadline) {
              throw new MemoryError("BUSY", "Memory storage is busy; no commit was acknowledged. Retry the same operation key.");
            }
            await Bun.sleep(20 * (attempt + 1));
            continue;
          }
          throw this.validation(error);
        }
      }
      throw new MemoryError("BUSY", "Memory storage is busy");
    });
    this.queue = task.catch(() => {});
    return task;
  }

  private validation(error: unknown): Error {
    if (error instanceof z.ZodError) return new MemoryError("INVALID_ARGUMENT", error.issues.map(i => `${i.path.join(".")}: ${i.message}`).join("; "));
    if (error instanceof MemoryError) return error;
    return new MemoryError("UNAVAILABLE", "Memory storage is unavailable; preserve the database and use recovery controls");
  }

  private context(source: ContextSource): MemoryContext {
    if (this.closed) throw new MemoryError("UNAVAILABLE", "Memory service is closed");
    const ctx = typeof source === "function" ? source() : source;
    if (ctx.owner_id !== this.ownerId || !["agent", "app"].includes(ctx.actor)) throw new MemoryError("FORBIDDEN", "Local memory owner does not match");
    if (ctx.actor === "agent" && (!ctx.project_id || !ctx.session_id || !ctx.checkout_id || !ctx.run_id)) {
      throw new MemoryError("FORBIDDEN", "A verified live project, session, checkout and run are required");
    }
    return ctx;
  }

  private dispatch(ctx: MemoryContext, request: MemoryRequest): Record<string, unknown> {
    if (ctx.actor === "agent" && ["settings", "list", "export", "repair"].includes(request.op)) throw new MemoryError("FORBIDDEN", "This operation requires app inspection");
    switch (request.op) {
      case "status": return this.status(ctx);
      case "settings": return this.settings(ctx, request);
      case "search": return this.search(ctx, request.query, request.limit);
      case "list": return this.list(ctx, request.history, request.offset);
      case "get": return { record: this.record(this.requireRecord(ctx, request.id, request.history)) };
      case "prepare": return this.prepare(ctx, request.operation_key, redactSave(request.save));
      case "save": return this.save(ctx, request.operation_key, redactSave(request.save));
      case "forget": return this.forget(ctx, request.id);
      case "export": return this.exportPage(ctx, request.cursor);
      case "repair": this.store.repair(); this.cleanup(); return this.status(ctx);
      default: throw new MemoryError("INVALID_ARGUMENT", "Unsupported memory operation");
    }
  }

  private status(ctx: MemoryContext): Record<string, unknown> {
    const profile = this.store.query("SELECT * FROM profile WHERE singleton=1").get() as { enabled: number; paused: number; cleanup_pending: number };
    const project = ctx.project_id ? this.store.query("SELECT paused FROM project_settings WHERE project_id=?").get(ctx.project_id) as { paused: number } | null : null;
    const failedOperations = this.operationCount(ctx, "failure_code IS NOT NULL");
    return { available: true, search_status: this.store.searchReady ? "ready" : "search_unavailable", enabled: !!profile.enabled, paused: !!profile.paused, failed_operations: failedOperations,
      project_paused: !!project?.paused, pending_operations: this.operationCount(ctx, "state='pending'"), recovery_status: profile.cleanup_pending ? "cleanup_failed" : "ready" };
  }

  private settings(ctx: MemoryContext, request: Extract<MemoryRequest, { op: "settings" }>): Record<string, unknown> {
    if (ctx.project_id && (request.paused !== undefined || request.enabled === false)) throw new MemoryError("FORBIDDEN", "Change profile controls from machine settings");
    if (!ctx.project_id && request.project_paused !== undefined) throw new MemoryError("INVALID_ARGUMENT", "Project pause requires a project context");
    this.store.db.transaction(() => {
      if (request.enabled !== undefined) this.store.query("UPDATE profile SET enabled=? WHERE singleton=1").run(+request.enabled);
      if (request.paused !== undefined) this.store.query("UPDATE profile SET paused=? WHERE singleton=1").run(+request.paused);
      if (request.project_paused !== undefined) this.store.query("INSERT INTO project_settings VALUES(?,?) ON CONFLICT(project_id) DO UPDATE SET paused=excluded.paused").run(ctx.project_id!, +request.project_paused);
    }).immediate();
    return this.status(ctx);
  }

  private writable(ctx: MemoryContext): void {
    if (ctx.actor !== "agent") return;
    const status = this.status(ctx);
    if (!status.enabled) throw new MemoryError("DISABLED", "Enable Antgrid Memory once in app settings before saving");
    if (status.paused || status.project_paused) throw new MemoryError("PAUSED", "Agent saving is paused, including explicit remember requests. Recall and forgetting remain available.");
  }

  private eligible(row: Row, at = this.now()): boolean { return !row.superseded_by && !(row.memory_type === "task_state" && at - row.updated_at >= TASK_EXPIRY_MS); }
  private allowed(ctx: MemoryContext, row: Row): boolean {
    if (row.owner_id !== ctx.owner_id) return false;
    if (ctx.actor === "app") return !ctx.project_id || (row.scope !== "user" && row.project_id === ctx.project_id);
    return (row.scope === "user" || row.project_id === ctx.project_id)
      && (row.scope !== "task" || row.task_id === ctx.session_id)
      && (!row.checkout_id || row.checkout_id === ctx.checkout_id);
  }
  private requireRecord(ctx: MemoryContext, id: string, history = true): Row {
    const row = this.store.query("SELECT * FROM records WHERE id=?").get(id) as Row | null;
    if (!row || !this.allowed(ctx, row) || (!history && !this.eligible(row))) throw new MemoryError("NOT_FOUND", "Memory is not available in this context");
    return row;
  }
  private record(row: Row, at = this.now()): MemoryRecord {
    return MemoryRecordSchema.parse({
      id: row.id, owner_id: row.owner_id, scope: row.scope, memory_type: row.memory_type, content: row.content,
      ...(row.project_id === null ? {} : { project_id: row.project_id }), ...(row.task_id === null ? {} : { task_id: row.task_id }),
      ...(row.checkout_id === null ? {} : { checkout_id: row.checkout_id }), ...(row.applicability === null ? {} : { applicability: row.applicability }),
      evidence: JSON.parse(row.evidence), source: JSON.parse(row.source),
      ...(row.supersedes === null ? {} : { supersedes: row.supersedes }), ...(row.superseded_by === null ? {} : { superseded_by: row.superseded_by }),
      created_at: row.created_at, updated_at: row.updated_at,
      lifecycle: row.superseded_by ? "superseded" : this.eligible(row, at) ? "active" : "expired",
    });
  }

  private filter(ctx: MemoryContext, history: boolean): { sql: string; args: (string | number)[] } {
    let sql = "r.owner_id=?";
    const args: (string | number)[] = [ctx.owner_id];
    if (ctx.actor === "app") {
      if (ctx.project_id) { sql += " AND r.scope!='user' AND r.project_id=?"; args.push(ctx.project_id); }
    } else {
      sql += " AND (r.scope='user' OR r.project_id=?) AND (r.scope!='task' OR r.task_id=?) AND (r.checkout_id IS NULL OR r.checkout_id=?)";
      args.push(ctx.project_id!, ctx.session_id!, ctx.checkout_id!);
    }
    if (!history) { sql += " AND r.superseded_by IS NULL AND (r.memory_type!='task_state' OR r.updated_at>?)"; args.push(this.now() - TASK_EXPIRY_MS); }
    return { sql, args };
  }
  private exportPage(ctx: MemoryContext, cursor?: string): Record<string, unknown> {
    // The revision and rows share a SQLite snapshot. No long-lived transaction
    // holds forgetting or saves open while the app collects subsequent pages.
    return this.store.db.transaction(() => {
      const state = this.store.query("SELECT revision,cursor_key FROM export_state WHERE singleton=1").get() as { revision: number; cursor_key: string };
      const previous = cursor ? readCursor(cursor, state.cursor_key) : undefined;
      const binding = this.binding(ctx);
      if (previous && previous.binding !== binding) throw new MemoryError("FORBIDDEN", "Memory export cursor belongs to a different inspection context");
      if (previous && previous.revision !== state.revision) throw new MemoryError("EXPORT_CHANGED", "Memories changed during export; discard these pages and start a new export");
      const exportedAt = previous?.exported_at ?? this.now();
      const { sql, args } = this.filter(ctx, true);
      const rows = this.store.query(`SELECT r.* FROM records r WHERE ${sql} AND r.id>? ORDER BY r.id ASC LIMIT ?`)
        .all(...args, previous?.last_id ?? "", LIMITS.exportRecords + 1) as Row[];
      const result = { version: 1, owner_id: this.ownerId, exported_at: exportedAt, records: [] as MemoryRecord[], next_cursor: null as string | null };
      for (const row of rows.slice(0, LIMITS.exportRecords)) {
        const record = this.record(row, exportedAt);
        const nextCursor = signCursor({ version: 1, binding, revision: state.revision, last_id: row.id, exported_at: exportedAt }, state.cursor_key);
        result.records.push(record);
        if (bytes({ ...result, next_cursor: nextCursor }) > LIMITS.exportPage) { result.records.pop(); break; }
        result.next_cursor = nextCursor;
      }
      if (rows.length > 0 && result.records.length === 0) throw new MemoryError("UNAVAILABLE", "A memory record exceeds the export page limit; preserve the database for recovery");
      if (result.records.length === rows.length) result.next_cursor = null;
      return result;
    }).deferred();
  }
  private list(ctx: MemoryContext, history: boolean, offset: number): Record<string, unknown> {
    const { sql, args } = this.filter(ctx, history);
    const rows = this.store.query(`SELECT r.* FROM records r WHERE ${sql} ORDER BY r.created_at DESC,r.id LIMIT 51 OFFSET ?`).all(...args, offset) as Row[];
    return { results: rows.slice(0, 50).map(r => this.record(r)), has_more: rows.length > 50 };
  }
  private search(ctx: MemoryContext, query: string, limit: number): Record<string, unknown> {
    const match = ftsQuery(query);
    if (!this.store.searchReady) throw new MemoryError("SEARCH_UNAVAILABLE", "Memory search index needs repair; direct history inspection remains available");
    const { sql, args } = this.filter(ctx, false);
    try {
      const rows = this.store.query(`SELECT r.* FROM memory_fts JOIN records r ON r.id=memory_fts.id WHERE memory_fts MATCH ? AND ${sql} ORDER BY rank ASC,r.id ASC LIMIT ?`).all(match, ...args, limit + 1) as Row[];
      return searchResponse(rows.map(r => this.record(r)), limit);
    } catch (error) {
      if (isBusy(error)) throw error;
      this.store.searchReady = false;
      throw new MemoryError("SEARCH_UNAVAILABLE", "Memory search failed; rebuild the index without replacing the database");
    }
  }

  private binding(ctx: MemoryContext): string { return hash([ctx.owner_id, ctx.actor, ctx.project_id ?? null, ctx.actor === "agent" ? ctx.session_id : null]); }
  private placement(ctx: MemoryContext, save: MemorySave): Placement {
    if (save.supersedes) {
      const old = this.requireRecord(ctx, save.supersedes);
      if (save.scope !== old.scope) throw new MemoryError("FORBIDDEN", "Corrections cannot change scope");
      return { scope: old.scope, project_id: old.project_id, task_id: old.task_id, checkout_id: old.checkout_id };
    }
    if (ctx.actor === "app") throw new MemoryError("FORBIDDEN", "App edits must correct an existing memory");
    return { scope: save.scope, project_id: save.scope === "user" ? null : ctx.project_id!, task_id: save.scope === "task" ? ctx.session_id! : null,
      checkout_id: save.scope === "task" && save.restrict_to_checkout ? ctx.checkout_id! : null };
  }
  private operation(ctx: MemoryContext, key: string): Operation | null {
    return this.store.query("SELECT * FROM operations WHERE binding=? AND operation_key=?").get(this.binding(ctx), key) as Operation | null;
  }
  private identity(ctx: MemoryContext, save: MemorySave, placement: Placement) {
    return { payloadHash: hash([ctx.owner_id, placement, save]), matchHash: hash([ctx.owner_id, placement, save.memory_type, save.content, save.applicability ?? null]) };
  }
  private checkOperation(ctx: MemoryContext, operation: Operation | null, payloadHash: string): SaveResult | undefined {
    if (!operation) return;
    if (operation.state === "suppressed") throw new MemoryError("FORGOTTEN", "This operation was consumed by forgetting and cannot be replayed");
    if (operation.payload_hash !== payloadHash) throw new MemoryError("IDEMPOTENCY_CONFLICT", "Operation key was already used with different content or scope");
    if (operation.state === "resolved") {
      if (operation.failure_code) throw new MemoryError(operation.failure_code, "This correction conflicted with a newer revision; inspect it before creating another operation");
      const row = this.requireRecord(ctx, operation.record_id!);
      return { operation_key: operation.operation_key, id: row.id, outcome: operation.outcome!, lifecycle: this.record(row).lifecycle };
    }
  }
  private preflightOperation(ctx: MemoryContext, key: string): Operation | null {
    const operation = this.operation(ctx, key);
    // This must precede resolving a correction target that forgetting removed.
    if (operation?.state === "suppressed") throw new MemoryError("FORGOTTEN", "This operation was consumed by forgetting and cannot be replayed");
    return operation;
  }
  private prepare(ctx: MemoryContext, key: string, save: MemorySave): Record<string, unknown> {
    this.writable(ctx);
    return this.store.db.transaction(() => {
      const operation = this.preflightOperation(ctx, key);
      const placement = this.placement(ctx, save);
      const { payloadHash, matchHash } = this.identity(ctx, save, placement);
      this.checkOperation(ctx, operation, payloadHash);
      if (operation) return { operation_key: key, state: operation.state };
      const row = this.makeRow(ctx, save, placement, matchHash);
      this.store.query("INSERT INTO operations(binding,operation_key,payload_hash,match_hash,target_id,payload,origin_project_id,state) VALUES(?,?,?,?,?,?,?,'pending')")
        .run(this.binding(ctx), key, payloadHash, matchHash, save.supersedes ?? null, JSON.stringify({ save, source: JSON.parse(row.source) }), ctx.project_id ?? null);
      return { operation_key: key, state: "pending" };
    }).immediate();
  }

  private makeRow(ctx: MemoryContext, save: MemorySave, placement: Placement, matchHash: string): Row {
    const source = { actor: ctx.actor, ...(ctx.project_id ? { project_id: ctx.project_id } : {}), ...(ctx.session_id ? { session_id: ctx.session_id } : {}),
      ...(ctx.checkout_id ? { checkout_id: ctx.checkout_id } : {}), ...(ctx.agent_id ? { agent_id: ctx.agent_id } : {}) };
    const now = this.now();
    const row: Row = { id: crypto.randomUUID(), owner_id: ctx.owner_id, ...placement, memory_type: save.memory_type, content: save.content,
      applicability: save.applicability ?? null, evidence: JSON.stringify(save.evidence), source: JSON.stringify(source),
      supersedes: save.supersedes ?? null, superseded_by: null, created_at: now, updated_at: now, match_hash: matchHash };
    const size = bytes(this.record(row));
    if (size > LIMITS.record) throw new MemoryError("INVALID_ARGUMENT", `record: ${size} bytes exceeds ${LIMITS.record} byte limit`);
    return row;
  }
  private save(ctx: MemoryContext, key: string, save: MemorySave): SaveResult {
    this.writable(ctx);
    if (!this.store.searchReady) throw new MemoryError("SEARCH_UNAVAILABLE", "Repair search before saving; a save must commit its index atomically");
    const result = this.store.db.transaction((): SaveResult | MemoryError => {
      const operation = this.preflightOperation(ctx, key);
      const placement = this.placement(ctx, save);
      const { payloadHash, matchHash } = this.identity(ctx, save, placement);
      const replay = this.checkOperation(ctx, operation, payloadHash);
      if (replay) return replay;
      if (save.supersedes && this.requireRecord(ctx, save.supersedes).superseded_by) {
        this.store.query(`INSERT INTO operations(binding,operation_key,payload_hash,target_id,origin_project_id,state,failure_code) VALUES(?,?,?,?,?,'resolved','CONFLICT')
          ON CONFLICT(binding,operation_key) DO UPDATE SET state='resolved',payload=NULL,failure_code='CONFLICT'`)
          .run(this.binding(ctx), key, payloadHash, save.supersedes, ctx.project_id ?? null);
        return new MemoryError("CONFLICT", "Memory has already been corrected; inspect the latest revision");
      }
      let row: Row | undefined;
      if (!save.supersedes) row = (this.store.query("SELECT * FROM records WHERE match_hash=? ORDER BY id").all(matchHash) as Row[]).find(r => this.allowed(ctx, r) && this.eligible(r));
      const outcome = row ? "already_present" : "saved";
      if (!row) {
        row = this.makeRow(ctx, save, placement, matchHash);
        if (operation?.payload) row.source = JSON.stringify(JSON.parse(operation.payload).source);
        const size = bytes(this.record(row));
        if (size > LIMITS.record) throw new MemoryError("INVALID_ARGUMENT", `record: ${size} bytes exceeds ${LIMITS.record} byte limit`);
        if (save.supersedes) {
          const previous = { ...this.requireRecord(ctx, save.supersedes), superseded_by: row.id };
          if (bytes(this.record(previous)) > LIMITS.record) throw new MemoryError("INVALID_ARGUMENT", "Correction history metadata would exceed the 16384 byte record limit");
          this.store.query("UPDATE records SET superseded_by=? WHERE id=? AND superseded_by IS NULL").run(row.id, save.supersedes);
        }
        this.store.query(`INSERT INTO records(id,owner_id,scope,project_id,task_id,checkout_id,memory_type,content,applicability,evidence,source,supersedes,superseded_by,created_at,updated_at,match_hash)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).run(row.id,row.owner_id,row.scope,row.project_id,row.task_id,row.checkout_id,row.memory_type,row.content,row.applicability,row.evidence,row.source,row.supersedes,row.superseded_by,row.created_at,row.updated_at,row.match_hash);
      }
      this.store.query(`INSERT INTO operations(binding,operation_key,payload_hash,match_hash,target_id,record_id,outcome,state) VALUES(?,?,?,?,?,?,?,'resolved')
        ON CONFLICT(binding,operation_key) DO UPDATE SET record_id=excluded.record_id,outcome=excluded.outcome,state='resolved',payload=NULL`)
        .run(this.binding(ctx), key, payloadHash, matchHash, save.supersedes ?? null, row.id, outcome);
      return { operation_key: key, id: row.id, outcome, lifecycle: this.record(row).lifecycle };
    }).immediate();
    if (result instanceof MemoryError) throw result;
    return result;
  }

  private pending(ctx: MemoryContext): Operation[] {
    if (ctx.actor === "agent") return this.store.query("SELECT * FROM operations WHERE binding=? AND state='pending' ORDER BY operation_key").all(this.binding(ctx)) as Operation[];
    const operations = this.store.query("SELECT * FROM operations WHERE state='pending'").all() as Operation[];
    if (!ctx.project_id) return operations;
    return operations.filter(op => op.origin_project_id === ctx.project_id);
  }
  private operationCount(ctx: MemoryContext, predicate: string): number {
    const args: string[] = [];
    if (ctx.actor === "agent") { predicate += " AND binding=?"; args.push(this.binding(ctx)); }
    else if (ctx.project_id) { predicate += " AND origin_project_id=?"; args.push(ctx.project_id); }
    return (this.store.query(`SELECT count(*) AS count FROM operations WHERE ${predicate}`).get(...args) as { count: number }).count;
  }
  private async recover(context: ContextSource, deadline: number): Promise<Record<string, unknown>> {
    const ctx = this.context(context);
    if (ctx.actor !== "agent") throw new MemoryError("FORBIDDEN", "Only a verified live agent can recover its durable-session operations");
    const recovered: SaveResult[] = [];
    const errors: { operation_key: string; code: string; message: string }[] = [];
    for (const operation of this.pending(ctx)) {
      if (performance.now() >= deadline) break;
      try {
        for (let attempt = 0; attempt < 3; attempt++) {
          try {
            if (performance.now() >= deadline) throw new MemoryError("BUSY", "Pending save exceeded its recovery deadline");
            const current = this.context(context);
            if (this.binding(current) !== operation.binding) throw new MemoryError("FORBIDDEN", "Caller binding changed before recovery");
            recovered.push(this.save(current, operation.operation_key, redactSave(JSON.parse(operation.payload!).save)));
            break;
          } catch (error) {
            if (!isBusy(error) || attempt === 2 || performance.now() + 80 >= deadline) throw error;
            await Bun.sleep(20 * (attempt + 1));
          }
        }
      } catch (error) {
        const e = isBusy(error) ? new MemoryError("BUSY", "Memory storage is busy") : this.validation(error);
        errors.push({ operation_key: operation.operation_key, code: e instanceof MemoryError ? e.code : "UNAVAILABLE", message: e.message });
      }
    }
    return { recovered, pending_operations: this.operationCount(this.context(context), "state='pending'"), errors };
  }

  private forget(ctx: MemoryContext, id: string): Record<string, unknown> {
    this.store.db.transaction(() => {
      const addressed = this.requireRecord(ctx, id);
      const chain = new Map<string, Row>([[addressed.id, addressed]]);
      for (const row of chain.values()) {
        for (const related of this.store.query("SELECT * FROM records WHERE id=? OR id=? OR supersedes=?").all(row.supersedes, row.superseded_by, row.id) as Row[]) {
          if (!this.allowed(ctx, related)) throw new MemoryError("FORBIDDEN", "Correction history crosses the authorized context");
          chain.set(related.id, related);
        }
      }
      for (const row of chain.values()) {
        this.store.query(`UPDATE operations SET state='suppressed',payload=NULL,payload_hash=NULL,match_hash=NULL,target_id=NULL,record_id=NULL,outcome=NULL,origin_project_id=NULL,failure_code=NULL
          WHERE record_id=? OR target_id=? OR (state='pending' AND match_hash=?)`).run(row.id, row.id, row.match_hash);
        this.store.query("DELETE FROM records WHERE id=?").run(row.id);
      }
      this.store.db.exec("UPDATE profile SET cleanup_pending=1 WHERE singleton=1");
    }).immediate();
    this.cleanup();
    return { forgotten: true, cleanup: "complete" };
  }

  private cleanup(): void {
    try {
      const result = this.store.query("PRAGMA wal_checkpoint(TRUNCATE)").all()[0] as { busy: number };
      if (result.busy) throw new Error("Checkpoint is held by a reader");
      this.store.db.exec("UPDATE profile SET cleanup_pending=0 WHERE singleton=1");
    } catch {
      throw new MemoryError("CLEANUP_FAILED", "Forgotten content is hidden and pending operations are suppressed, but local storage cleanup needs retry through Repair");
    }
  }
}
