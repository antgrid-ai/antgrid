// bridge/src/handler/brief.ts
import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { extractJsonObject } from "./json-extract";

export const BriefSchema = z.object({
  taskSummary: z.string(),
  willHandle: z.array(z.string()),
  wakeFor: z.array(z.string()),
  doneWhen: z.string().optional(),
  thenItems: z.array(z.string()),
});
export type Brief = z.infer<typeof BriefSchema>;

export interface LedgerEntry { item: string; evidence: string; at: number; }

// An unanswered escalation. The engine keeps the full payload (not just a
// count) so a phone that reconnects — or an app that restarts — can rebuild an
// answerable "needs you" row from the status snapshot instead of showing a
// badge that points at nothing.
export const OpenEscalationSchema = z.object({
  escalationId: z.string(),
  question: z.string(),
  reasoning: z.string(),
  draftReply: z.string(),
  urgency: z.enum(["normal", "high"]),
  floorRule: z.string().optional(),
  kind: z.enum(["reply", "resolve_in_session"]).optional(),
  at: z.number(),
});
export type OpenEscalation = z.infer<typeof OpenEscalationSchema>;

export const HandlerSessionRecordSchema = z.object({
  version: z.literal(1),
  terminalId: z.string(),
  armed: z.boolean(),
  brief: BriefSchema,
  notifyOnly: z.boolean(),
  armedAt: z.number(),
  doneWhenMet: z.boolean(),
  ledger: z.array(z.object({ item: z.string(), evidence: z.string(), at: z.number() })),
  // default() keeps records written before escalation persistence readable.
  escalations: z.array(OpenEscalationSchema).default([]),
  // Per-session judge choice (absent = the session's own tool / CLI default
  // model). Optional on version 1 deliberately: a version bump would fail
  // safeParse on every pre-existing record and silently drop armed sessions
  // across a bridge restart.
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
  // Park state, so a bridge restart mid-park strands nothing. Optional for the
  // same reason as judgeTool above.
  parkKind: z.enum(["limit", "outage"]).optional(),
  parkedUntil: z.number().optional(),
  transientFailures: z.number().optional(),
  // Whether the parked pause still owes a judge a verdict. The stashed event
  // itself is too stale to persist, but nudging without this would let a
  // restart resume an unsupervised turn.
  parkAwaitingJudge: z.boolean().optional(),
});
export type HandlerSessionRecord = z.infer<typeof HandlerSessionRecordSchema>;

function sessionPath(abDir: string, projectId: string, terminalId: string): string {
  // terminalId is a bridge-issued slot id, but sanitize anyway: a path separator
  // in the id must not escape the project dir.
  return join(abDir, "agents", projectId, `handler-session-${encodeURIComponent(terminalId)}.json`);
}

export function loadHandlerSession(abDir: string, projectId: string, terminalId: string): HandlerSessionRecord | null {
  const path = sessionPath(abDir, projectId, terminalId);
  if (!existsSync(path)) return null;
  try {
    const parsed = HandlerSessionRecordSchema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}

export function saveHandlerSession(abDir: string, projectId: string, rec: HandlerSessionRecord): void {
  const path = sessionPath(abDir, projectId, rec.terminalId);
  mkdirSync(join(abDir, "agents", projectId), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(rec, null, 2), "utf8");
  renameSync(tmp, path);
  if (process.platform !== "win32") { try { chmodSync(path, 0o600); } catch { /* ignore */ } }
}

export function remainingThenItems(brief: Brief, ledger: LedgerEntry[]): string[] {
  const satisfied = new Set(ledger.map((e) => e.item));
  return brief.thenItems.filter((i) => !satisfied.has(i));
}

export function renderLedger(brief: Brief, ledger: LedgerEntry[]): string {
  const satisfied = ledger.map((e) => `- [satisfied] ${e.item} — ${e.evidence}`);
  const remaining = remainingThenItems(brief, ledger).map((i) => `- [remaining] ${i}`);
  if (!satisfied.length && !remaining.length) return "(no follow-up items)";
  return [...satisfied, ...remaining].join("\n");
}

export function buildPlanPrompt(context: string, transcriptPath?: string): string {
  return [
    "You are about to supervise a coding agent session on the user's behalf while they step away.",
    "Read the session context and produce a concrete, session-specific supervision plan.",
    "",
    "SESSION CONTEXT:",
    context,
    ...(transcriptPath ? ["", `Fuller transcript at ${transcriptPath} — read it if the excerpt is insufficient.`] : []),
    "",
    "Produce:",
    "- taskSummary: ONE sentence: what the agent is working on right now.",
    "- willHandle: 3-5 concrete bullets you will auto-answer (routine prompts, safe continuations).",
    "- wakeFor: concrete bullets that must escalate to the user (product decisions, destructive/irreversible actions, repeated failures).",
    "- doneWhen: a verifiable completion condition inferred from the session, or omit if none is clear.",
    "- thenItems: follow-up steps the user would plausibly want after completion (e.g. run tests, code review); omit freely.",
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    '{"taskSummary":"...","willHandle":["..."],"wakeFor":["..."],"doneWhen":"...","thenItems":["..."]}',
  ].join("\n");
}

export function parseBriefFromOutput(stdout: string): Brief | null {
  const obj = extractJsonObject(stdout);
  if (obj === null) return null;
  const parsed = BriefSchema.safeParse(obj);
  return parsed.success ? parsed.data : null;
}
