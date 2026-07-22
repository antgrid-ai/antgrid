import { z } from "zod";

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
});
export type HandlerDecision = z.infer<typeof HandlerDecisionSchema>;

// claude/codex/opencode each accept a one-shot prompt in non-interactive mode and
// print to stdout. Returning null gates Handler off for tools without a verified
// headless judge (gemini/cursor/etc) — they escalate-only, never auto-reply.
export function buildJudgeCommand(
  tool: string, model: string | undefined, prompt: string,
): string[] | null {
  switch (tool) {
    case "claude-code": return ["claude", "-p", ...(model ? ["--model", model] : []), prompt];
    case "codex":       return ["codex", "exec", ...(model ? ["-m", model] : []), prompt];
    case "opencode":    return ["opencode", "run", ...(model ? ["--model", model] : []), prompt];
    default:            return null;
  }
}

export function buildJudgePrompt(guidance: string, context: string): string {
  return [
    "You are a supervisor standing in for the user while a coding agent works.",
    "Decide whether to let the agent continue, answer it on the user's behalf, or escalate to the user.",
    "",
    "POLICY:",
    guidance,
    "If you cannot answer with high confidence, escalate. A wrong auto-reply is the expensive failure.",
    "",
    "RECENT CONTEXT:",
    context,
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    '{"decision":"continue|handle|escalate","confidence":0.0,"reason":"...","reply":"(when handle) text to send the agent","action":{"kind":"slash_command|none","value":"/cmd"},"notify":{"title":"...","body":"...","draftReply":"...","urgency":"normal|high"}}',
  ].join("\n");
}

export function parseDecisionFromOutput(stdout: string): HandlerDecision | null {
  const match = stdout.match(/\{[\s\S]*\}/);
  if (!match) return null;
  try {
    const parsed = HandlerDecisionSchema.safeParse(JSON.parse(match[0]));
    return parsed.success ? parsed.data : null;
  } catch {
    return null;
  }
}
