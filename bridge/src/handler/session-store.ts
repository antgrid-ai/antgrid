// bridge/src/handler/session-store.ts
import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { BacklogSchema } from "./backlog";

// One tap-to-answer option on a quick-choice escalation (§4.6). `text` is sent as
// the USER's own reply through the ordinary reply transport, so it must be
// something a session can actually receive: whitespace alone is dropped by every
// consumer, which turns the chip into a button that silently does nothing.
// Control characters are rejected rather than flattened — a one-tap sends text the
// user never opened in an editable field, and an embedded CR would submit two lines
// into the PTY.
//
// `choiceId` names the intent so a notification action can round-trip back to the
// app; it is identity, never authority. Nothing may derive an authorization lift
// from it (see quickChoicesFor in engine.ts).
export const EscalationChoiceSchema = z.object({
  choiceId: z.string().min(1).max(40),
  label: z.string().min(1).max(40),
  text: z.string().min(1).max(400).regex(/^[^\x00-\x1f\x7f]+$/).refine((t) => t.trim().length > 0),
});
export type EscalationChoice = z.infer<typeof EscalationChoiceSchema>;

// Ids resolve a tap to the text it sends, and every surface resolves them by
// first match — so a repeated id means the chip the user read is not the one that
// would be sent. Refined on the ARRAY, never the enclosing object, so
// OpenEscalationWire keeps the `.shape` protocol.ts spreads into its message.
const uniqueChoiceIds = (cs: EscalationChoice[]): boolean =>
  new Set(cs.map((c) => c.choiceId)).size === cs.length;

// What answers an escalation, which is also what retires it:
//  - `reply` (or absent) — a pause-question about the agent. Any submitted line
//    supersedes it, because each pause supersedes the last.
//  - `resolve_in_session` — an option-based agent prompt only the chat resolve
//    RPC can answer.
//  - `guard_blocked` — a REPORT that a harness guard refused an action Handler
//    wanted to take. Nothing the agent or the user does next answers it: the
//    action was never taken, so no later pause supersedes it and no resolve
//    names it. Only an explicit dismiss retires one (see the clearing rule in
//    onUserReply, and dismissEscalation in engine.ts).
//
// The enum only ever widens, so a record written before a member existed still
// parses; the reverse — an older bridge reading a newer record — fails the whole
// record and comes back disarmed, which is the trade `version`'s note already owns.
export const EscalationKindSchema = z.enum(["reply", "resolve_in_session", "guard_blocked"]);
export type EscalationKind = z.infer<typeof EscalationKindSchema>;

// An unanswered escalation. The engine keeps the full payload (not just a
// count) so a phone that reconnects — or an app that restarts — can rebuild an
// answerable "needs you" row from the status snapshot instead of showing a
// badge that points at nothing.
//
// Kept in lockstep with OpenEscalationWire (protocol.ts) and the Dart mirror in
// app/lib/models/handler_state.dart, except for `promptId` — see its note.
export const OpenEscalationSchema = z.object({
  escalationId: z.string(),
  question: z.string(),
  reasoning: z.string(),
  draftReply: z.string(),
  urgency: z.enum(["normal", "high"]),
  floorRule: z.string().optional(),
  kind: EscalationKindSchema.optional(),
  // `resolve_in_session` only: the driver's permissionId/questionId, so the
  // resolve RPC retires the row for the prompt it answered and leaves a second
  // prompt on the same terminal pending. Engine-internal — deliberately NOT in
  // OpenEscalationWire: the app resolves prompts from the transcript's own
  // frames, so mirroring it would publish an id no client has a use for.
  promptId: z.string().optional(),
  // §4.6 quick choices, optional exactly the way `kind` is: absent means "free-text
  // reply", so an app that predates this renders its reply sheet unchanged. Two is
  // the floor because one chip is a card with no alternative, and the free-text
  // escape hatch is app-authored — never an entry here — so no bridge can ship a
  // card without one.
  choices: z.array(EscalationChoiceSchema).min(2).max(3)
    .refine(uniqueChoiceIds, "choiceId must be unique").optional(),
  at: z.number(),
});
export type OpenEscalation = z.infer<typeof OpenEscalationSchema>;

export const HandlerSessionRecordSchema = z.object({
  // Version 2 rejects every record version 1 wrote, and loadHandlerSession turns
  // a failed parse into null — so a session armed across the upgrade comes back
  // disarmed. Accepted knowingly pre-release: the alternative is a brief→backlog
  // migration, i.e. the compatibility layer the clean-slate spec rules out. A
  // later bump inherits the same trade and has to re-decide it.
  version: z.literal(2),
  terminalId: z.string(),
  armed: z.boolean(),
  // Supervision stopped because the RUNTIME went away, not because the user
  // turned it off. The two are indistinguishable in `armed` alone, and every
  // host shutdown kills the PTYs — so without this, re-arming after a restart
  // reads the record as "the user disarmed" and discards the backlog and open
  // escalations it exists to carry across exactly that gap. Optional: absent
  // means a deliberate disarm (or a record written before this field).
  suspended: z.boolean().optional(),
  // The user's own words for the objective, plus the live instruction stack
  // driven off it. BacklogSchema rather than a bare array: a duplicate id leaves
  // the shadowed item undrivable and the session unable to wrap up, so a record
  // carrying one is better refused than rehydrated.
  goal: z.string(),
  backlog: BacklogSchema,
  notifyOnly: z.boolean(),
  armedAt: z.number(),
  escalations: z.array(OpenEscalationSchema),
  // Per-session judge choice (absent = the session's own tool / CLI default
  // model).
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
  // Park state, so a bridge restart mid-park strands nothing. Optional because
  // an unparked session genuinely has none.
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
