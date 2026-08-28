// bridge/src/handler/decision.ts
import { z } from "zod";
import { agentSpec } from "../agents/registry";
import { pickHeadlessFrom, type JudgeTier } from "../agents/types";
import { ItemTransitionSchema } from "./backlog";
import { extractJsonObject } from "./json-extract";

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

// Judge argv for an arbitrary tool string, read off the one place a tool is
// described. Tier and argv come back together because they are one field on the
// spec — a "readonly" claim and the flags that enforce it can no longer drift.
// Null = no VERIFIED headless judge for this tool, which gates Handler off.
export function buildJudgeCommand(
  tool: string, model: string | undefined, prompt: string,
): { cmd: string[]; tier: JudgeTier; env?: Record<string, string> } | null {
  const picked = pickHeadlessFrom(agentSpec(tool)?.headless, "repo");
  // "repo" cannot select a sealed entry; the check is what lets the reach narrow
  // to a JudgeTier without a cast, rather than a case that can actually happen.
  if (!picked || picked.reach === "sealed") return null;
  return { cmd: picked.command.cmd(prompt, model), tier: picked.reach, env: picked.command.env };
}

// The transition rules below restate what applyTransitions enforces. That is
// belt-and-braces, not the guard — a prompt cannot bind the component it is
// addressed to (spec §2.1). It earns its place by making well-formed output the
// likely one: an evaluator that answers in prose gets its progress dropped, and
// the item then sits open with nothing explaining why.
export function buildDecidePrompt(opts: {
  goal: string; backlogText: string; context: string; transcriptPath?: string;
  floorWarnings?: string[];
}): string {
  return [
    "You are a supervisor standing in for the user while a coding agent works.",
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
    "- Every transition to `done`, `skipped` or `failed` MUST carry `evidence`: a short verbatim quote from the context or transcript. One without it is discarded and the item stays open, so quote rather than paraphrase.",
    "- Report `done` only on evidence the work actually happened (test output, exit codes, a diff), never on intent or belief. `outcome` is your one-line summary for the user and never substitutes for evidence.",
    "- An item the agent has already satisfied on its own is `done` with that evidence — do not drive it again.",
    "",
    "RULES:",
    "- Escalating always trumps making progress: if the next step on an item needs the user, escalate instead of transitioning it.",
    "- If you cannot answer with high confidence, escalate. A wrong auto-reply is the expensive failure.",
    "- Safety limits are enforced after your decision; never attempt to bypass them.",
    // The point of turning the floor advisory (§5.1) is that the Assistant sees
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
    "",
    "RECENT CONTEXT:",
    opts.context,
    ...(opts.transcriptPath ? ["", `Fuller transcript at ${opts.transcriptPath} — read it if the excerpt is insufficient.`] : []),
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    '{"decision":"continue|handle|escalate","confidence":0.0,"reason":"...","reply":"(when handle) text to send the agent","action":{"kind":"slash_command|none","value":"/cmd"},"notify":{"title":"...","body":"...","draftReply":"...","urgency":"normal|high"},"transitions":[{"id":"...","status":"queued|active|done|blocked|skipped|failed","evidence":"verbatim quote","outcome":"..."}]}',
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

export function parseDecisionFromOutput(stdout: string): { decision: HandlerDecision | null; error?: string } {
  const obj = extractJsonObject(stdout);
  if (obj === null) return { decision: null, error: "no JSON object found in output" };
  const parsed = HandlerDecisionSchema.safeParse(obj);
  if (parsed.success) return { decision: parsed.data };
  return { decision: null, error: parsed.error.message.slice(0, 500) };
}
