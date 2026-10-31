import { existsSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import {
  MEMORY_DATABASE, MEMORY_OFF, MemoryError, MemoryRequestSchema, MemoryService, readMemoryEnabled, type MemoryContext,
} from "antgrid-memory";
import type { SchedulerCallerDeps } from "./scheduler-caller";
import { formatZodIssues } from "./config";
import type { WorkStatus } from "./protocol";

export type MemoryCaller = Pick<MemoryContext, "session_id" | "checkout_id" | "agent_id" | "run_id">;
export type MemoryForAgent = (caller: () => MemoryCaller, request: unknown) => Promise<Record<string, unknown>>;
export type MemoryForApp = (request: unknown, validate: () => void, peerId?: string) => Promise<Record<string, unknown>>;

/** A running session launched without the Memory MCP server, as the app's status answer lists it. */
export type SessionWithoutMemory = {
  project_id: string;
  project_label: string;
  session_id: string;
  name: string;
  work_status?: WorkStatus;
  agent_session_resumable: boolean;
};

export interface MemoryCallerDeps extends Pick<SchedulerCallerDeps, "session" | "isLiveRun" | "runAgent"> {
  checkoutExists(id: string): boolean;
}

export function resolveMemoryCaller(deps: MemoryCallerDeps, terminalId?: string, runId?: string): MemoryCaller {
  const refuse = () => new MemoryError("NOT_A_SESSION", "Memory requires a verified live Antgrid terminal session.");
  if (!terminalId || !runId) throw refuse();
  const session = deps.session(terminalId);
  if (!session || session.archived || session.mode !== "terminal" || session.command
    || !deps.isLiveRun(terminalId, runId)) throw refuse();
  const agentId = deps.runAgent(terminalId, runId);
  // A missing or unloaded checkout must not inherit main's access. The session
  // and runtime are both checked, unlike the general-purpose terminal lookup.
  if (!agentId || !session.checkoutId || !deps.checkoutExists(session.checkoutId)) throw refuse();
  return { session_id: session.id, checkout_id: session.checkoutId, agent_id: agentId, run_id: runId };
}

export function memoryFailure(error: unknown): { code: string; message: string } {
  if (error instanceof MemoryError) return { code: error.code, message: error.message };
  if (error instanceof z.ZodError) return { code: "INVALID_ARGUMENT", message: formatZodIssues(error.issues).join("; ") };
  return { code: "UNAVAILABLE", message: "Memory storage is unavailable. Existing records have been retained." };
}

/** The answer for an owner who never opted in: nothing is stored, so nothing is created to say so. */
const NEVER_ENABLED_STATUS = {
  available: true, search_status: "ready", enabled: false, paused: false, failed_operations: 0,
  project_paused: false, pending_operations: 0, recovery_status: "ready",
} as const;

/**
 * One store per host. The store is created only when the user turns memory on,
 * so an install that never opted in gains no directory, no database and no
 * work at launch. Failure is isolated from project/session startup.
 */
export class HostMemory {
  private service?: MemoryService;
  private error?: { code: string; message: string };
  private closed = false;
  private enabledCache?: boolean;
  private warmTimer?: ReturnType<typeof setTimeout>;

  constructor(
    private readonly profileDirectory: () => string,
    private readonly catalog: () => Iterable<{ project_id: string; label?: string }> = () => [],
    // The host passes a direct lookup so a settings write does not build labels for the whole catalog.
    private readonly isCataloged: (projectId: string) => boolean = (projectId) => {
      for (const entry of this.catalog()) if (entry.project_id === projectId) return true;
      return false;
    },
    private readonly sessionsWithoutMemory: () => SessionWithoutMemory[] = () => [],
  ) {}

  private directory(): string { return join(this.profileDirectory(), "memory"); }
  private storePresent(): boolean { return existsSync(join(this.directory(), MEMORY_DATABASE)); }

  private open(): MemoryService | undefined {
    if (!this.service && !this.error) {
      try { this.service = new MemoryService({ directory: this.directory() }); }
      catch (error) { this.error = memoryFailure(error); }
    }
    return this.service;
  }

  /**
   * Synchronous launch-time gate: whether agent launches should be offered the
   * memory server. A launch cannot await the store, so this reads the profile
   * flag directly and then serves the cached value until a settings change.
   */
  launchEnabled(): boolean {
    if (this.closed || !this.storePresent()) return false;
    if (this.enabledCache === undefined) {
      const enabled = readMemoryEnabled(this.directory());
      if (enabled === undefined) return false;
      this.enabledCache = enabled;
    }
    return this.enabledCache;
  }

  /** Opens an existing store shortly after host start so the first agent hook is not what pays for it. */
  warm(delayMs = 2000): void {
    if (this.warmTimer || this.closed || !this.storePresent()) return;
    this.warmTimer = setTimeout(() => {
      this.warmTimer = undefined;
      if (this.closed || this.service) return;
      void this.execute(() => ({ actor: "app" }), { op: "status" }).catch(() => {});
    }, delayMs);
    this.warmTimer.unref?.();
  }

  private absentAnswer(request: unknown, actor: "agent" | "app"): Record<string, unknown> | "create" {
    const op = MemoryRequestSchema.parse(request);
    if (actor === "app" && (op.op === "repair" || (op.op === "settings" && op.enabled === true))) return "create";
    if (actor === "agent" && op.op !== "status") throw new MemoryError("DISABLED", MEMORY_OFF);
    switch (op.op) {
      // An agent's absent-store status reaches /memory/status raw, and agents never get a `failures` key.
      case "status": case "settings": return actor === "app" ? { ...NEVER_ENABLED_STATUS, failures: [] } : { ...NEVER_ENABLED_STATUS };
      case "dismiss": return { ...NEVER_ENABLED_STATUS, failures: [] };
      case "projects": return { projects: [], memories: 0, earlier_versions: 0 };
      case "recover": return { recovered: [], pending_operations: 0, errors: [] };
      case "search": case "list": return { results: [], has_more: false, total: 0 };
      case "export": throw new MemoryError("NOT_FOUND", "Memory has never been turned on, so there is nothing to export");
      case "get": case "forget": throw new MemoryError("NOT_FOUND", "Memory is not available in this context");
      default: throw new MemoryError("DISABLED", MEMORY_OFF);
    }
  }

  private enrichProjects(result: Record<string, unknown>, scoped: boolean): Record<string, unknown> {
    const labels = new Map<string, string | undefined>();
    for (const entry of this.catalog()) labels.set(entry.project_id, entry.label);
    type Row = { project_id: string; memories: number; earlier_versions: number; paused: boolean; label?: string; cataloged?: boolean };
    const rows: Row[] = [];
    for (const row of (result.projects as Row[] | undefined) ?? []) {
      const cataloged = labels.has(row.project_id);
      // project_settings rows are never deleted (an unpause upserts paused=0), so a removed project that only
      // ever had a setting would otherwise sit in the Project dropdown forever as an empty entry nobody can clear.
      if (!cataloged && row.memories === 0 && row.earlier_versions === 0) continue;
      const label = labels.get(row.project_id);
      rows.push({ ...row, ...(label !== undefined ? { label } : {}), cataloged });
    }
    if (!scoped) {
      const present = new Set(rows.map((row) => row.project_id));
      for (const [id, label] of labels) {
        if (present.has(id)) continue;
        rows.push({ project_id: id, memories: 0, earlier_versions: 0, paused: false, ...(label !== undefined ? { label } : {}), cataloged: true });
      }
    }
    return { ...result, projects: rows };
  }

  async execute(
    context: () => Omit<MemoryContext, "owner_id">,
    request: unknown,
    maxAttempts: 1 | 3 = 3,
  ): Promise<Record<string, unknown>> {
    if (this.closed) throw new MemoryError("UNAVAILABLE", "The memory host has stopped.");
    const caller = context();
    const op = typeof request === "object" && request !== null && "op" in request ? request.op : undefined;
    if (caller.actor === "app" && this.error && op === "repair") this.error = undefined;
    const enrich = caller.actor === "app" && op === "projects";
    if (caller.actor === "app" && !caller.project_id && op === "settings") {
      const target = (request as { project_id?: unknown }).project_id;
      if (typeof target === "string" && !this.isCataloged(target)) {
        throw new MemoryError("NOT_FOUND", "This project is not in this machine's catalog");
      }
    }
    if (!this.service && !this.error && !this.storePresent()) {
      const answer = this.absentAnswer(request, caller.actor);
      if (answer !== "create") return enrich ? this.enrichProjects(answer, !!caller.project_id) : answer;
    }
    const service = this.open();
    if (!service) {
      if (op === "status") return { available: false, error: this.error };
      throw new MemoryError("UNAVAILABLE", this.error?.message ?? "Memory storage is unavailable.");
    }
    const result = await service.execute(() => {
      if (this.closed) throw new MemoryError("UNAVAILABLE", "The memory host has stopped.");
      return { ...context(), owner_id: service.ownerId };
    }, request, { maxAttempts });
    if ((op === "status" || op === "settings" || op === "repair" || op === "dismiss") && typeof result.enabled === "boolean") this.enabledCache = result.enabled;
    if (caller.actor === "app" && !caller.project_id && op === "status" && result.enabled === true) {
      return { ...result, sessions_without_memory: this.sessionsWithoutMemory() };
    }
    return enrich ? this.enrichProjects(result, !!caller.project_id) : result;
  }

  close(): void {
    this.closed = true;
    if (this.warmTimer) clearTimeout(this.warmTimer);
    this.service?.close();
    this.service = undefined;
  }
}
