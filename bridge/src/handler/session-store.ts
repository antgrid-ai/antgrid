// bridge/src/handler/session-store.ts
import { z } from "zod";
import { existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { BacklogSchema, clip } from "./backlog";

// One entry's ceiling, in lockstep with HandlerInstructWire.text (../protocol.ts):
// an instruction reaches this list straight off that wire, and the arm-time
// `goal` — which the configure wire does NOT bound, because a length refused
// there would drop the arm it rode in on — is clipped to the same size here.
// Declared rather than imported: protocol.ts imports this module.
export const MAX_INSTRUCTION_CHARS = 10_000;

// How many the record keeps. The whole stack is re-read on every load and the
// newest entries are the ones still standing, so the oldest are what go.
export const MAX_INSTRUCTIONS = 50;

// One thing the user asked for, in their own words. `at` orders the list against
// the activity feed; the ORDER is what says which sentence supersedes which, so
// nothing may sort this list by anything else.
export const InstructionEntrySchema = z.object({
  text: z.string().max(MAX_INSTRUCTION_CHARS),
  at: z.number(),
});
export type InstructionEntry = z.infer<typeof InstructionEntrySchema>;

/** One instruction as the record stores it, or "" for nothing to store. */
export function normalizeInstruction(raw: string): string {
  return clip(raw.trim(), MAX_INSTRUCTION_CHARS, "");
}

/** Append one already-normalized instruction, dropping the oldest past the cap —
 *  the same end the prompt budget trims from, and for the same reason. */
export function pushInstruction(list: InstructionEntry[], text: string, at: number): void {
  list.push({ text, at });
  if (list.length > MAX_INSTRUCTIONS) list.splice(0, list.length - MAX_INSTRUCTIONS);
}

// One tap-to-answer option on a quick-choice escalation. `text` is sent as
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
  // Non-empty refined on top of `.min(1)`: a whitespace-only label is truthy but
  // draws a blank button on the card that stops the session.
  label: z.string().min(1).max(40).regex(/^[^\x00-\x1f\x7f]+$/).refine((t) => t.trim().length > 0),
  text: z.string().min(1).max(400).regex(/^[^\x00-\x1f\x7f]+$/).refine((t) => t.trim().length > 0),
  // What taking this chip commits to, one clause, shown under the button. New and
  // optional, so no bound any row already on disk was written under moves and an app
  // that predates it renders exactly what it renders today.
  cost: z.string().min(1).max(160).regex(/^[^\x00-\x1f\x7f]+$/)
    .refine((t) => t.trim().length > 0).optional(),
});
export type EscalationChoice = z.infer<typeof EscalationChoiceSchema>;

// Ids resolve a tap to the text it sends, and every surface resolves them by
// first match — so a repeated id means the chip the user read is not the one that
// would be sent. Refined on the ARRAY, never the enclosing object, so
// OpenEscalationWire keeps the `.shape` protocol.ts spreads into its message.
//
// Typed on the id alone so the ask options below share this exact rule rather
// than growing a second copy of it: the property being defended is about ids, not
// about which of the two option shapes carries them.
const uniqueChoiceIds = (cs: { choiceId: string }[]): boolean =>
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
// `nonBlocking` cuts ACROSS this enum and is retirement-relevant in its own
// right: an ask is minted `reply`, and yet no submitted line supersedes it,
// because it is a question Handler put to the user rather than a pause waiting on
// the agent. What retires one is the answer itself — a `handler:answer` tap or a
// `handler:instruct` naming its escalationId — or a dismiss (the user declining),
// or reconcileAsks finding nothing left in the backlog that the question gated.
// Reading the kind alone therefore does not tell you what takes a row away.
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
  // Quick choices, optional exactly the way `kind` is: absent means "free-text
  // reply", so an app that predates this renders its reply sheet unchanged. Two is
  // the floor because one chip is a card with no alternative, and the free-text
  // escape hatch is app-authored — never an entry here — so no bridge can ship a
  // card without one.
  choices: z.array(EscalationChoiceSchema).min(2).max(3)
    .refine(uniqueChoiceIds, "choiceId must be unique").optional(),
  at: z.number(),
  // The session did NOT stop for this one: it was raised on a pass that had
  // already replied to the agent, so the work went on and the user answers when
  // they can. Absent means what every row before this field meant — the session
  // stopped and is waiting.
  //
  // Spelled `nonBlocking` and not `blocking` on purpose: the naive truthiness
  // test (`if (e.nonBlocking)`) is then the SAFE reading on a row that predates
  // the field AND on one an older bridge stripped it from and re-persisted.
  // `blocking?: boolean` inverts that, and the failure is one character wide,
  // silent, and repeated at every reader in two languages.
  //
  // RETIREMENT-RELEVANT, not merely a rendering flag: a submitted line does NOT
  // clear one (see onUserReply's clearing rule). What retires one is an
  // escalationId-bearing handler:answer or handler:instruct, a dismiss, or
  // reconcileAsks finding nothing left that the question does not gate.
  nonBlocking: z.boolean().optional(),
  // Backlog ids the answer does not gate, validated once at raise time and
  // re-checked against the live backlog on every pass (reconcileAsks) — the app
  // re-derives the count from its own copy of the backlog rather than trusting
  // a number, so the claim is verified at render time and not only at mint time.
  unblocked: z.array(z.string().max(64)).max(10).optional(),
  // The tap-to-answer options on an ASK. A separate field from `choices` and
  // never a second producer into it: a `choices` entry carries `text` that the
  // ordinary reply transport types into the PTY, and an ask must send the agent
  // nothing. There is deliberately no `text` here — `label` IS the whole payload,
  // resolved bridge-side from this row, so what the user reads on the button is
  // exactly what the judge is told they chose. See quickChoicesFor's comment in
  // handler/engine.ts for the authorization argument this shape rests on.
  //
  // `label` is bounded at 80 rather than the 40 EscalationChoiceSchema allows
  // because there a label only names a reply that travels separately, while here
  // it has to carry the whole answer as a sentence. Widening this one costs
  // nothing — it is a new field, so no bound an existing row was written under
  // moves.
  askOptions: z.array(z.object({
    choiceId: z.string().min(1).max(40),
    label: z.string().min(1).max(80),
    cost: z.string().min(1).max(160),
    // z.literal(true), not z.boolean(): absent and `false` must mean one thing,
    // and a literal makes the second spelling unsayable.
    recommended: z.literal(true).optional(),
  })).min(2).max(4).refine(uniqueChoiceIds, "choiceId must be unique").optional(),
});
export type OpenEscalation = z.infer<typeof OpenEscalationSchema>;

export const HandlerSessionRecordSchema = z.object({
  // Version 2 rejects every record version 1 wrote, and loadHandlerSession turns
  // a failed parse into null — so a session armed across the upgrade comes back
  // disarmed. Accepted knowingly pre-release: `z.literal(2)` keeps exactly one
  // readable shape, where a brief→backlog migration would owe a second schema
  // plus a translation that has to stay correct for the life of the field. The
  // cost is paid once, by every session armed at the moment of the upgrade, and
  // re-arming cannot recover the backlog v1 wrote. A later bump inherits the
  // same trade and has to re-decide it.
  //
  // `instructions` arrived without one, and that is the trade re-decided rather
  // than skipped: the field is seeded from `goal` on read, so a version-2 record
  // carries everything the new shape needs and a bump would spend a whole
  // project's backlogs to say nothing extra.
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
  // The FIRST instruction, mirrored. Never the source of truth — `instructions`
  // is — and kept for two readers that cannot use the list: a bridge predating it
  // (which reads this record as the session's objective and carries on), and the
  // seeding below, which is the only way a record written before the list existed
  // says anything about what the user asked for.
  goal: z.string(),
  // Everything the user has asked for on this session, verbatim and in order.
  // Verbatim because the judge prompt prints the list and a paraphrase there is a
  // different instruction; in order because a later sentence supersedes an
  // earlier one and nothing else records which came first.
  //
  // `.default([])` rather than `.optional()`: every record ever written carries a
  // `goal` and none carried this, so absence has to resolve to a value
  // seedInstructionsFromGoal can fill rather than to a second spelling of "empty"
  // that every reader would then have to handle.
  instructions: z.array(InstructionEntrySchema).max(MAX_INSTRUCTIONS).default([]),
  // BacklogSchema rather than a bare array: a duplicate id leaves the shadowed
  // item undrivable and the session unable to wrap up, so a record carrying one
  // is better refused than rehydrated.
  backlog: BacklogSchema,
  armedAt: z.number(),
  escalations: z.array(OpenEscalationSchema),
  // Per-session judge choice (absent = the session's own tool / CLI default
  // model).
  judgeTool: z.string().optional(),
  judgeModel: z.string().optional(),
  // The retired posture. Kept on the schema, and as a lenient string, only so a
  // record any bridge ever wrote still parses: this schema nulls the WHOLE record
  // on one unreadable value and arm() then rebuilds an empty session, so a posture
  // spelling this build does not know would cost the user their backlog. Read for
  // the one line that says it selected nothing; never written again.
  personality: z.string().optional(),
  // The session's lens, and the user's brief beneath it. Lenient strings rather
  // than the wire enum on purpose: loadHandlerSession turns ANY parse failure into
  // null and arm() then rebuilds an empty session — goal "", no backlog, no
  // escalations, no parked answer — so a single value this build does not recognise
  // would silently cost the user their backlog. The engine resolves an unknown lens
  // to the unnamed default and clips the brief to the prompt budget.
  role: z.string().optional(),
  brief: z.string().optional(),
  // Park state, so a bridge restart mid-park strands nothing. Optional because
  // an unparked session genuinely has none.
  parkKind: z.enum(["limit", "outage"]).optional(),
  // The backoff policy above says how long to wait; this says who the wait is
  // attributable to, and only this may be rendered as a reason. Absent on a
  // record written before the field existed, which a restart must survive rather
  // than treat as an unreadable value.
  parkCause: z.enum(["agent_limit", "agent_failure", "judge_failure"]).optional(),
  parkedUntil: z.number().optional(),
  transientFailures: z.number().optional(),
  // Whether the parked pause still owes a judge a verdict. The stashed event
  // itself is too stale to persist, but nudging without this would let a
  // restart resume an unsupervised turn.
  parkAwaitingJudge: z.boolean().optional(),
  // The user's answer to a standing ask, parked until the judge relays it.
  // Persisted, unlike askRejections and floorWarnings: a rejection lost to a
  // restart costs the judge a hint, but an ANSWER lost to one costs the user
  // their answer with the ask row already retired — they see nothing and believe
  // they answered. This disk format's rule is that an unreadable distinction
  // degrades to a halt, never to silence.
  //
  // Engine-internal and deliberately NOT on the wire, the same carve-out
  // `promptId` documents: what the app needs is the one bit saying an answer is
  // still queued, which rides the snapshot as `askAnswerPending`.
  askAnswer: z.object({
    escalationId: z.string(), question: z.string(), answer: z.string(),
    tapped: z.boolean(), at: z.number(),
    // Which kind of question this answers, and the two differ in what the judge
    // must then DO. An ask's answer reached nobody but the judge, so it has to be
    // relayed. A blocking escalation's answer went straight into the session, so
    // relaying it lands a second copy of an instruction the agent already has.
    //
    // Spelled `blocking` and z.literal(true) for the polarity `nonBlocking` uses
    // one level up: absent is what every record written before this field meant,
    // and that is the ask case.
    blocking: z.literal(true).optional(),
  }).optional(),
  // Whether the last ask raiseAsk raised named an `unblocked` set with nothing
  // still open in it — see the field's own comment on ArmedSession (engine.ts).
  // Persisted, unlike askRejections and floorWarnings: the row it describes is
  // a real escalation on `escalations` above, not a rejection note, so it
  // outlives a restart and the judge's feedback about it must too.
  staleAskIds: z.boolean().optional(),
  // How much of the citation re-ask budget this session has already spent — see
  // MAX_EVIDENCE_REASKS (engine.ts). Persisted because a session that stopped
  // moving is diagnosed from this file and nothing else says it was ever in a
  // refusal episode. Optional rather than `.default(0)`, matching its neighbours:
  // every record written before this field lacks it, and the budget is a SPEND —
  // so the conservative reading of an absent value is none spent, which is what
  // the engine's `?? 0` gives it.
  //
  // Engine-internal and deliberately not on the wire, exactly as
  // `transientFailures` above is.
  evidenceReasks: z.number().int().min(0).optional(),
  // The refusals that budget was spent on, and the text the escalation it ends in
  // puts on the card. Persisted WITH the counter and never apart from it: restored
  // out of lockstep, a resumed session carries a spend with nothing to say what it
  // was for, and the card it eventually raises names no item, no quote and no
  // reason while blocking wrap-up until somebody dismisses it. That is also what
  // makes the counter above genuinely diagnosable from this file.
  //
  // Bounded at the mint (MAX_REMEMBERED_REJECTIONS, engine.ts) rather than here,
  // for the reason OpenEscalation's `question` gives: a `.max()` fails the whole
  // record over a list a bug made too long, and a failed parse brings the session
  // back disarmed with an empty backlog.
  evidenceRejections: z.array(z.object({ id: z.string(), line: z.string() })).optional(),
});
export type HandlerSessionRecord = z.infer<typeof HandlerSessionRecordSchema>;

function sessionPath(abDir: string, projectId: string, terminalId: string): string {
  // terminalId is a bridge-issued slot id, but sanitize anyway: a path separator
  // in the id must not escape the project dir.
  return join(abDir, "agents", projectId, `handler-session-${encodeURIComponent(terminalId)}.json`);
}

/**
 * A record as every reader wants it: `instructions` filled from `goal` for one
 * written before the list existed.
 *
 * Applied at each read rather than once at upgrade, because nothing rewrites a
 * disarmed session's file — a record can sit in the old shape for as long as the
 * user leaves that session alone. Idempotent, so a reader that has its own record
 * source (an injected loader, a test) can apply it without knowing whether the
 * store already did.
 */
export function seedInstructionsFromGoal(rec: HandlerSessionRecord): HandlerSessionRecord {
  if (rec.instructions.length > 0) return rec;
  const text = normalizeInstruction(rec.goal);
  if (text === "") return rec;
  return { ...rec, instructions: [{ text, at: rec.armedAt }] };
}

export function loadHandlerSession(abDir: string, projectId: string, terminalId: string): HandlerSessionRecord | null {
  const path = sessionPath(abDir, projectId, terminalId);
  if (!existsSync(path)) return null;
  try {
    const parsed = HandlerSessionRecordSchema.safeParse(JSON.parse(readFileSync(path, "utf8")));
    return parsed.success ? seedInstructionsFromGoal(parsed.data) : null;
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
