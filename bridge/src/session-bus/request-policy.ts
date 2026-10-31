// What another machine may ask this one to do over the bus, decided from three
// facts the requester cannot author: the method, the requester's role as the
// account's directory reports it, and this machine's effective reach level.
//
// Kept apart from the dispatcher so the whole matrix is one table that a test
// can walk, and so a method added to the host cannot become reachable without
// being named here.
import { z } from "zod";
import type { SessionEntry } from "../protocol";
import type { SessionBusErrorCode } from "./errors";

export type AgentReachLevel = "off" | "messages" | "control";
export type BusRole = "agent" | "orchestrator";

export const BUS_READ_METHODS = ["machine.capability-card", "sessions.list"] as const;
// Never `scheduler.*`: a scheduled run is its owner's, not another machine's.
export const BUS_CONTROL_METHODS = ["project.start", "session.create", "session.start", "session.stop"] as const;

export type BusReadMethod = (typeof BUS_READ_METHODS)[number];
export type BusControlMethod = (typeof BUS_CONTROL_METHODS)[number];

const READ = new Set<string>(BUS_READ_METHODS);
const CONTROL = new Set<string>(BUS_CONTROL_METHODS);

/** Local off always wins. `control` needs the owner-set grant on top of a local
 *  `on`, so nothing on this machine can raise it past what the owner set. */
export function effectiveReachLevel(localEnabled: boolean, selfBusControl: boolean): AgentReachLevel {
  if (!localEnabled) return "off";
  return selfBusControl ? "control" : "messages";
}

export function isBusMethod(method: string): boolean {
  return READ.has(method) || CONTROL.has(method);
}

export function busRequestVerdict(i: {
  method: string;
  role: BusRole;
  level: AgentReachLevel;
}): "allow" | { code: Extract<SessionBusErrorCode, "METHOD_NOT_ALLOWED" | "NOT_ALLOWED_AGENT_REACH" | "NOT_ORCHESTRATOR"> } {
  if (READ.has(i.method)) return i.level === "off" ? { code: "NOT_ALLOWED_AGENT_REACH" } : "allow";
  if (!CONTROL.has(i.method)) return { code: "METHOD_NOT_ALLOWED" };
  if (i.level !== "control") return { code: "NOT_ALLOWED_AGENT_REACH" };
  return i.role === "orchestrator" ? "allow" : { code: "NOT_ORCHESTRATOR" };
}

const projectId = z.string().min(1).max(200);
const sessionId = z.string().min(1).max(200);

// Strict on every schema. `session.create` in particular takes no `command`,
// `args` or `approvalPolicy`: a program on another machine cannot choose what
// executable a session runs or lift its approval prompts.
export const BUS_PARAMS = {
  "project.start": z.strictObject({ projectId }),
  "session.create": z.strictObject({
    projectId,
    name: z.string().max(120).optional(),
    tool: z.string().regex(/^[a-z0-9-]{1,64}$/).optional(),
    mode: z.enum(["terminal", "chat"]).optional(),
    isolation: z.enum(["shared", "worktree"]).optional(),
    baseBranch: z.string().min(1).optional(),
  }),
  "session.start": z.strictObject({ projectId, sessionId, initialPrompt: z.string().max(32_768).optional() }),
  "session.stop": z.strictObject({ projectId, sessionId }),
  "sessions.list": z.strictObject({ projectId }),
} as const;

export type BusParamsMethod = keyof typeof BUS_PARAMS;

/** The only fields of a session that leave the machine over the bus. An
 *  allowlist, so a field added to the wire entry later stays here until
 *  someone chooses to send it; transcript paths and agent conversation ids in
 *  particular never do. */
export const BUS_SESSION_ROW_KEYS = [
  "id", "name", "tool", "agentKey", "mode", "running", "archived", "workStatus",
  "checkoutKind", "checkoutBranch", "createdAt", "lastUsedAt",
] as const satisfies readonly (keyof SessionEntry)[];

export function busSessionRow(entry: SessionEntry): Record<string, unknown> {
  const row: Record<string, unknown> = {};
  for (const key of BUS_SESSION_ROW_KEYS) {
    if (entry[key] !== undefined) row[key] = entry[key];
  }
  return row;
}
