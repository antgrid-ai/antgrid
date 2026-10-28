import { join } from "node:path";
import { z } from "zod";
import { MemoryError, MemoryService, type MemoryContext } from "antgrid-memory";
import type { SessionEntry } from "./protocol";

export type MemoryCaller = Pick<MemoryContext, "session_id" | "checkout_id" | "agent_id" | "run_id">;
export type MemoryForAgent = (caller: () => MemoryCaller, request: unknown) => Promise<Record<string, unknown>>;
export type MemoryForApp = (request: unknown, validate: () => void, peerId?: string) => Promise<Record<string, unknown>>;

export interface MemoryCallerDeps {
  session(id: string): SessionEntry | undefined;
  isLiveRun(id: string, runId: string): boolean;
  runAgent(id: string, runId: string): string | undefined;
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
  if (error instanceof z.ZodError) return { code: "INVALID_ARGUMENT", message: error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ") };
  return { code: "UNAVAILABLE", message: "Memory storage is unavailable. Existing records have been retained." };
}

/** One store per host. Failure is isolated from project/session startup. */
export class HostMemory {
  private service?: MemoryService;
  private error?: { code: string; message: string };
  private closed = false;

  constructor(private readonly profileDirectory: () => string) {}

  private open(): MemoryService | undefined {
    if (!this.service && !this.error) {
      try { this.service = new MemoryService({ directory: join(this.profileDirectory(), "memory") }); }
      catch (error) { this.error = memoryFailure(error); }
    }
    return this.service;
  }

  async execute(
    context: () => Omit<MemoryContext, "owner_id">,
    request: unknown,
    maxAttempts: 1 | 3 = 3,
  ): Promise<Record<string, unknown>> {
    if (this.closed) throw new MemoryError("UNAVAILABLE", "The memory host has stopped.");
    const caller = context();
    if (caller.actor === "app" && this.error && typeof request === "object" && request !== null && "op" in request && request.op === "repair") {
      this.error = undefined;
    }
    const service = this.open();
    if (!service) {
      if (typeof request === "object" && request !== null && "op" in request && request.op === "status") {
        return { status: "unavailable", available: false, error: this.error };
      }
      throw new MemoryError("UNAVAILABLE", this.error?.message ?? "Memory storage is unavailable.");
    }
    return service.execute(() => {
      if (this.closed) throw new MemoryError("UNAVAILABLE", "The memory host has stopped.");
      return { ...context(), owner_id: service.ownerId };
    }, request, { maxAttempts });
  }

  close(): void {
    this.closed = true;
    this.service?.close();
    this.service = undefined;
  }
}
