// bridge/src/handler/decision.ts
import { z } from "zod";
import { agentSpec } from "../agents/registry";
import { pickHeadlessFrom, type HeadlessCommand, type JudgeTier } from "../agents/types";
import type { CapCommand } from "../structured/chat-session";
import { ItemTransitionSchema } from "./backlog";
import { extractJsonObject } from "./json-extract";
import { MAX_REPLY_CHARS } from "./reply-shape";

export const HandlerDecisionSchema = z.object({
  decision: z.enum(["continue", "handle", "escalate"]),
  confidence: z.number().min(0).max(1),
  reason: z.string(),
  reply: z.string().optional(),
  action: z.object({
    kind: z.enum(["slash_command", "none"]),
    value: z.string(),
  }).optional(),
  notify: z.object({
    title: z.string(),
    body: z.string(),
    draftReply: z.string(),
    urgency: z.enum(["normal", "high"]),
  }).optional(),
  // Progress is reported as moves against existing ids, never as prose: the same
  // schema applyTransitions re-validates, so what the evaluator may say and what
  // the engine will accept cannot drift apart.
  transitions: z.array(ItemTransitionSchema).optional(),
});
export type HandlerDecision = z.infer<typeof HandlerDecisionSchema>;

// Re-exported, not redefined: the reaches an agent declares live on
// AgentSpec.headless, and a second spelling here could drift from them.
export type { JudgeTier } from "../agents/types";

// The judge command for an arbitrary tool string, read off the one place a tool
// is described. Tier and command come back together because they are one field
// on the spec — a "readonly" claim and the flags that enforce it can no longer
// drift. Null = no VERIFIED headless judge for this tool, which gates Handler
// off. The COMMAND, not one built argv: a judge run retries with a second
// prompt, and both attempts must come from the same entry.
export function pickJudge(
  tool: string,
): { command: HeadlessCommand; tier: JudgeTier } | null {
  const picked = pickHeadlessFrom(agentSpec(tool)?.headless, "repo");
  // "repo" cannot select a sealed entry; the check is what lets the reach narrow
  // to a JudgeTier without a cast, rather than a case that can actually happen.
  if (!picked || picked.reach === "sealed") return null;
  return { command: picked.command, tier: picked.reach };
}

// The CLI name, not the AgentKey and not the display label: the judge is
// reading a transcript the agent itself wrote, where `claude` appears and
// `claude-code` (our routing key) never does.
function supervisedName(tool: string): string {
  return agentSpec(tool)?.bin ?? tool;
}

// Command names and descriptions come verbatim from filesystem frontmatter and
// can carry newlines that would break the one-entry-per-line rendering.
function promptLine(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

// The transition rules below restate what applyTransitions enforces. That is
// belt-and-braces, not the guard — a prompt cannot bind the component it is
// addressed to. It earns its place by making well-formed output the likely one:
// an evaluator that answers in prose gets its progress dropped, and the item
// then sits open with nothing explaining why. The refused-transitions
// section is the same bargain one pass later: the harness has already dropped
// those moves, and stating why is what stops the next pass re-citing identically.
export function buildDecidePrompt(opts: {
  goal: string; backlogText: string; context: string; transcriptPath?: string;
  floorWarnings?: string[];
  evidenceRejections?: string[];
  // The agent being SUPERVISED, never the judge running this prompt — a
  // per-session judge pick can point at a different CLI entirely.
  agentTool?: string;
  // Non-empty or absent: an empty catalog is indistinguishable from a failed
  // or not-yet-landed discovery, so it is never announced as a complete set.
  commands?: CapCommand[];
}): string {
  return [
    opts.agentTool
      ? `You are a supervisor standing in for the user while the coding agent \`${supervisedName(opts.agentTool)}\` works.`
      : "You are a supervisor standing in for the user while a coding agent works.",
    "Decide whether to let the agent continue, answer it on the user's behalf, or escalate to the user.",
    "",
    "SESSION GOAL (the user's own words):",
    opts.goal || "(none stated)",
    "",
    "BACKLOG — the complete set of items you may report on. Each line starts with its id:",
    opts.backlogText || "(no items)",
    "",
    "REPORTING PROGRESS:",
    "- Report every item whose state changed as one entry in `transitions`.",
    "- Use ONLY the ids listed above, copied exactly. Any other id is discarded, and you cannot create an item — if the agent did something the backlog does not cover, describe it in `reason` instead.",
    "- Statuses: `queued` (waiting its turn — use it to revive a blocked item whose precondition is now met), `active` (being worked on now), `done` (finished), `blocked` (a precondition or dependency is unmet), `skipped` (no longer applicable — its condition turned out false, or a later item supersedes it), `failed` (attempted and could not be completed).",
    "- Every transition to `done`, `skipped` or `failed` MUST carry `evidence`: a short verbatim quote copied character-for-character out of the RECENT CONTEXT block below, at least a phrase long. The harness searches that block for your quote — a paraphrase, a summary, or a quote from anywhere else is discarded and the item stays open. Never quote the item's own wording back; that says nothing about what happened.",
    "- If an item names a slash command, `done` additionally requires a quote showing THAT command being invoked. A quote about some other, similar step does not close it, however real the quote is.",
    "- Report `done` only on evidence the work actually happened (test output, exit codes, a diff), never on intent or belief. `outcome` is your one-line summary for the user and never substitutes for evidence.",
    "- An item the agent has already satisfied on its own is `done` with that evidence — do not drive it again.",
    "",
    "RULES:",
    "- Escalating always trumps making progress: if the next step on an item needs the user, escalate instead of transitioning it.",
    "- If you cannot answer with high confidence, escalate. A wrong auto-reply is the expensive failure.",
    "- Safety limits are enforced after your decision; never attempt to bypass them.",
    `- \`reply\` is free text typed at the agent and submitted as ONE line, under ${MAX_REPLY_CHARS} characters. Write one line: a line break would submit early, so any you write are collapsed to spaces before sending.`,
    "- `action` with `kind: \"slash_command\"` types a command at the agent instead. `value` is `\"/verb\"` or `\"/verb <args>\"` — the verb is a single token with no spaces and no further `/`.",
    "- Set either `reply` or `action`, never both. A decision carrying both is refused and reaches the agent as nothing.",
    // The point of turning the floor advisory is that the Assistant sees
    // which of its own proposals were dangerous. Stating that these are its past
    // replies, not the agent's commands, is what makes them actionable.
    ...(opts.floorWarnings?.length
      ? [
        "",
        "SAFETY WARNINGS ON YOUR OWN EARLIER REPLIES — these were sent anyway, and are recorded for the user:",
        ...opts.floorWarnings.map((w) => `- ${w}`),
        "Weigh them when composing this reply. If the same risk is unavoidable here, escalate instead of repeating it.",
      ]
      : []),
    // Named as REFUSED, not as failed: the moves were well-formed and the judge
    // has no other way to learn they never landed — the backlog it is handed next
    // pass simply shows the items still open, which reads as work not yet done.
    ...(opts.evidenceRejections?.length
      ? [
        "",
        "TRANSITIONS THE HARNESS REFUSED LAST PASS — those items are still open:",
        ...opts.evidenceRejections.map((r) => `- ${r}`),
        "Cite differently or leave the item open; the same quote gets the same answer.",
      ]
      : []),
    // Two statements, never an empty header: an absent catalog is a real answer
    // (a PTY session has none and cannot get one), and announcing a "complete
    // set" that is empty would read as "this agent has no commands" — which is
    // exactly the case an absent catalog CANNOT distinguish.
    ...(opts.commands?.length
      ? [
        "",
        "AVAILABLE COMMANDS (the complete set for this session) — invoke one through `action`, never by typing it in `reply`:",
        ...opts.commands.map((c) => {
          const parts = [`- /${promptLine(c.name)}`];
          if (c.argHint) parts.push(`(args: ${promptLine(c.argHint)})`);
          if (c.description) parts.push(`— ${promptLine(c.description)}`);
          return parts.join(" ");
        }),
        "A `value` whose verb is not on this list is refused and reaches the agent as nothing.",
      ]
      : [
        "",
        "No command catalog is available for this session. Prefer plain instructions; use a slash command only if the goal or backlog names one explicitly.",
      ]),
    "",
    "RECENT CONTEXT:",
    opts.context,
    // The transcript is background for REASONING and never a citation source: the
    // harness grounds evidence against the RECENT CONTEXT block alone (it is the
    // only text it holds), so an unqualified invitation to read further is an
    // invitation to cite quotes every terminal transition then gets refused for.
    ...(opts.transcriptPath
      ? [
        "",
        `Fuller transcript at ${opts.transcriptPath} — read it if the excerpt is insufficient.`,
        "Read it for background only: every `evidence` quote must still be copied out of the RECENT CONTEXT block above, which is the only text the harness can search. If what closes an item is not in that block, leave the item open and say so in `reason`.",
      ]
      : []),
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    '{"decision":"continue|handle|escalate","confidence":0.0,"reason":"...","reply":"(when handle, and only if action is omitted) text to send the agent","action":{"kind":"slash_command|none","value":"/verb <args>"},"notify":{"title":"...","body":"...","draftReply":"...","urgency":"normal|high"},"transitions":[{"id":"...","status":"queued|active|done|blocked|skipped|failed","evidence":"verbatim quote","outcome":"..."}]}',
  ].join("\n");
}

export function buildRetryPrompt(originalPrompt: string, validationError: string): string {
  return [
    originalPrompt,
    "",
    `Your previous response was not a valid JSON object for this schema: ${validationError}`,
    "Respond again with ONLY the single JSON object.",
  ].join("\n");
}

// Distinct from buildRetryPrompt on purpose: a decision that parsed cleanly and
// then failed a harness rule has perfectly valid JSON, and telling it to fix its
// JSON teaches it to change the one thing it got right.
export function buildShapeRetryPrompt(originalPrompt: string, rejection: string): string {
  return [
    originalPrompt,
    "",
    `Your previous response was valid JSON, but the harness refused to send it: ${rejection}`,
    "It never reached the agent. Answer again obeying the rules above, or escalate instead if you cannot.",
    "Respond again with ONLY the single JSON object.",
  ].join("\n");
}

export function parseDecisionFromOutput(stdout: string): { decision: HandlerDecision | null; error?: string } {
  const obj = extractJsonObject(stdout);
  if (obj === null) return { decision: null, error: "no JSON object found in output" };
  const parsed = HandlerDecisionSchema.safeParse(obj);
  if (parsed.success) return { decision: parsed.data };
  return { decision: null, error: parsed.error.message.slice(0, 500) };
}
