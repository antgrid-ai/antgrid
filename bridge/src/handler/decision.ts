// bridge/src/handler/decision.ts
import { z } from "zod";
import { agentSpec } from "../agents/registry";
import type { Brief } from "./brief";
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
  satisfiedItems: z.array(z.object({ item: z.string(), evidence: z.string() })).optional(),
  doneWhenMet: z.boolean().optional(),
});
export type HandlerDecision = z.infer<typeof HandlerDecisionSchema>;

export type JudgeTier = "readonly" | "transcript";

// Judge argv for an arbitrary tool string, read off the one place a tool is
// described. Tier and argv come back together because they are one field on the
// spec — a "readonly" claim and the flags that enforce it can no longer drift.
// Null = no VERIFIED headless judge for this tool, which gates Handler off.
export function buildJudgeCommand(
  tool: string, model: string | undefined, prompt: string,
): { cmd: string[]; tier: JudgeTier } | null {
  const judge = agentSpec(tool)?.judge;
  return judge ? { cmd: judge.cmd(prompt, model), tier: judge.tier } : null;
}

export function buildDecidePrompt(opts: {
  brief: Brief; ledgerText: string; context: string; transcriptPath?: string;
}): string {
  const { brief } = opts;
  return [
    "You are a supervisor standing in for the user while a coding agent works.",
    "Decide whether to let the agent continue, answer it on the user's behalf, or escalate to the user.",
    "",
    "STANDING ORDERS (user-approved for this session):",
    `TASK: ${brief.taskSummary}`,
    "AUTO-ANSWER (handle):",
    ...brief.willHandle.map((b) => `- ${b}`),
    "WAKE THE USER FOR (escalate):",
    ...brief.wakeFor.map((b) => `- ${b}`),
    `DONE WHEN: ${brief.doneWhen ?? "(not defined)"}`,
    "FOLLOW-UPS (initiate in order once the task is done; skip any already satisfied):",
    opts.ledgerText || "(none)",
    "",
    "RULES:",
    "- Before initiating any follow-up, check the transcript and ledger for evidence it is already satisfied; if so, report it in satisfiedItems instead of re-running.",
    "- The wake-the-user rules always trump follow-up progress.",
    "- If you cannot answer with high confidence, escalate. A wrong auto-reply is the expensive failure.",
    "- Safety limits are enforced after your decision; never attempt to bypass them.",
    "- Report doneWhenMet: true only with concrete evidence in the context (test output, exit codes), never on belief.",
    "",
    "RECENT CONTEXT:",
    opts.context,
    ...(opts.transcriptPath ? ["", `Fuller transcript at ${opts.transcriptPath} — read it if the excerpt is insufficient.`] : []),
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    '{"decision":"continue|handle|escalate","confidence":0.0,"reason":"...","reply":"(when handle) text to send the agent","action":{"kind":"slash_command|none","value":"/cmd"},"notify":{"title":"...","body":"...","draftReply":"...","urgency":"normal|high"},"satisfiedItems":[{"item":"...","evidence":"..."}],"doneWhenMet":false}',
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
