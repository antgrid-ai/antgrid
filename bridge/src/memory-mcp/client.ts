import { redactSave } from "antgrid-memory";

export interface MemoryApiError {
  error: { code: string; message: string };
  operation_key?: string;
}

type ApiReply = Record<string, unknown>;
type Request = (op: string, body: Record<string, unknown>, timeoutMs: number) => Promise<ApiReply>;
const TOOL_OPS = new Map([["memory_search", "search"], ["memory_get", "get"], ["memory_forget", "forget"]]);

function refusal(code: string, message: string, operation_key?: string): MemoryApiError & ApiReply {
  return { error: { code, message }, ...(operation_key ? { operation_key } : {}) };
}

function errorCode(reply: ApiReply): string | undefined {
  const error = reply.error;
  return error && typeof error === "object" && "code" in error ? String(error.code) : undefined;
}

function uncertainRefusal(operation_key: string, current: ApiReply, stage: "prepare" | "save"): ApiReply {
  return {
    ...refusal("UNKNOWN_OUTCOME", stage === "save"
      ? "An earlier save response was lost, so the commit outcome remains unknown. The current refusal does not prove the earlier save was absent. Keep this operation key for inspection or recovery."
      : "An earlier preparation response was lost, so the durable queue status remains unknown. No save was dispatched by this call. Keep this operation key for inspection or recovery.", operation_key),
    current_refusal: current.error,
  };
}

export function memoryApiIdentity(env: NodeJS.ProcessEnv = process.env) {
  const port = Number(env.ANTGRID_API_PORT);
  const terminalId = env.ANTGRID_TERMINAL_ID?.trim();
  const runId = env.ANTGRID_RUN_ID?.trim();
  if (!Number.isInteger(port) || port < 1 || port > 65535
    || !terminalId || terminalId.startsWith("${") || !runId || runId.startsWith("${")) return null;
  return { base: `http://127.0.0.1:${port}`, terminalId, runId };
}

export async function memoryApi(op: string, body: Record<string, unknown>, timeoutMs: number): Promise<ApiReply> {
  const identity = memoryApiIdentity();
  if (!identity) return refusal("NOT_A_SESSION", "Memory tools require a live terminal session started by Antgrid.");
  const url = new URL(`/memory/${op}`, identity.base);
  url.searchParams.set("terminalId", identity.terminalId);
  const response = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...body, runId: identity.runId }),
    signal: AbortSignal.timeout(Math.max(1, Math.floor(timeoutMs))),
  });
  const result: unknown = await response.json();
  if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("Invalid memory response");
  if (!response.ok && !("error" in result)) throw new Error("Invalid memory error response");
  return result as ApiReply;
}

/** The durable retry queue lives behind prepare, so a forget can suppress it
 * even while this MCP process is offline. MCP request IDs are intentionally
 * not operation keys: hosts may reuse them after a process restart. */
export class MemoryMcpClient {
  constructor(private readonly options: {
    request?: Request;
    now?: () => number;
    sleep?: (ms: number) => Promise<void>;
    operationKey?: () => string;
  } = {}) {}

  private get request(): Request { return this.options.request ?? memoryApi; }
  private get now(): () => number { return this.options.now ?? Date.now; }
  private async backoff(attempt: number): Promise<void> {
    await (this.options.sleep ?? (ms => new Promise(resolve => setTimeout(resolve, ms))))(50 * (attempt + 1));
  }

  async recover(): Promise<ApiReply> {
    try { return await this.request("recover", {}, 2_000); }
    catch { return refusal("UNKNOWN_OUTCOME", "Pending memory operations could not be checked. Their durable keys remain available for recovery."); }
  }

  async call(tool: string, args: Record<string, unknown>): Promise<ApiReply> {
    if (tool === "memory_save") return this.save(args);
    const op = TOOL_OPS.get(tool);
    if (!op) return refusal("INVALID_ARGUMENT", "Unknown memory tool.");
    try { return await this.request(op, args, 2_000); }
    catch {
      return refusal(op === "forget" ? "UNKNOWN_OUTCOME" : "UNAVAILABLE",
        op === "forget"
          ? "The forget outcome is unknown. Inspect the memory or retry forgetting its ID before assuming deletion completed."
          : "The memory service could not be reached. Ordinary work can continue.");
    }
  }

  private async save(args: Record<string, unknown>): Promise<ApiReply> {
    let save;
    try { save = redactSave(args); }
    catch (error) {
      return refusal("INVALID_ARGUMENT", error instanceof Error ? error.message : "Invalid memory save.");
    }
    const operation_key = (this.options.operationKey ?? (() => crypto.randomUUID()))();
    const body = { operation_key, save };
    const deadline = this.now() + 2_000;
    let prepared = false;
    let prepareUncertain = false;
    let uncertain = false;
    for (let attempt = 0; attempt < 3 && this.now() < deadline; attempt++) {
      if (!prepared) {
        try {
          const result = await this.request("prepare", body, Math.min(650, deadline - this.now()));
          const code = errorCode(result);
          if (code && code !== "BUSY") return prepareUncertain
            ? uncertainRefusal(operation_key, result, "prepare") : { ...result, operation_key };
          if (!code) {
            if (result.state === "suppressed") return refusal("FORGOTTEN", "This operation was suppressed by forgetting.", operation_key);
            prepared = true;
            uncertain = result.state === "resolved";
          }
        } catch { prepareUncertain = true; }
      }
      if (prepared && this.now() < deadline) {
        try {
          const result = await this.request("save", body, Math.min(650, deadline - this.now()));
          const code = errorCode(result);
          if (code !== "BUSY") return uncertain && code
            ? uncertainRefusal(operation_key, result, "save") : { ...result, operation_key };
        } catch { uncertain = true; }
      }
      if (attempt < 2 && deadline - this.now() > 50 * (attempt + 1)) await this.backoff(attempt);
    }
    if (!prepared) return refusal("UNKNOWN_OUTCOME", "The memory operation could not be prepared. Its durable queue status is unknown; no save was dispatched.", operation_key);
    return refusal(uncertain ? "UNKNOWN_OUTCOME" : "BUSY", uncertain
      ? "The save may have committed. The same operation key and redacted payload remain recoverable; do not infer absence or create a replacement retry."
      : "Memory storage remained busy. The prepared operation is retained for recovery.", operation_key);
  }
}
