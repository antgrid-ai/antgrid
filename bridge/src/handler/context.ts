// bridge/src/handler/context.ts
import { agentSpec } from "../agents/registry";

// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;
export function stripAnsi(s: string): string { return s.replace(ANSI, ""); }

// Budgets are tiered by call purpose: "plan" calls reason over more history than
// the tighter, higher-frequency "decide" calls. PTY scrollback is noisy (prompts,
// ANSI, progress spam) so its fallback budget is capped independent of purpose.
export const PLAN_MAX_CHARS = 28_000;
export const PLAN_MAX_MSGS = 50;
export const DECIDE_MAX_CHARS = 12_000;
export const DECIDE_MAX_MSGS = 20;
export const PTY_MAX_CHARS = 8_000;

export async function assembleContext(opts: {
  tool: string; transcriptPath?: string; agentSessionId?: string; recentPty: string;
  purpose: "plan" | "decide"; maxChars?: number;
  // What `recentPty` actually holds. PTY_MAX_CHARS exists to cap NOISE (prompts,
  // ANSI, progress spam), which a chat session's rendered snapshot doesn't have —
  // applying it there silently pinned chat sessions to 8k for every purpose, so
  // `plan` could never reach its larger budget on a chat slot.
  recentKind?: "pty" | "rendered";
  // Test seams; production callers omit both.
  codexHome?: string; opencodeDbPath?: string;
}): Promise<{ text: string; source: "transcript" | "pty"; transcriptPath?: string }> {
  const plan = opts.purpose === "plan";
  const maxChars = opts.maxChars ?? (plan ? PLAN_MAX_CHARS : DECIDE_MAX_CHARS);
  const maxMsgs = plan ? PLAN_MAX_MSGS : DECIDE_MAX_MSGS;
  const capped = (msgs: string[]) => msgs.join("\n---\n").slice(-maxChars);
  const read = agentSpec(opts.tool)?.transcript;
  if (read) {
    const t = await read({
      maxMsgs,
      transcriptPath: opts.transcriptPath,
      agentSessionId: opts.agentSessionId,
      codexHome: opts.codexHome,
      opencodeDbPath: opts.opencodeDbPath,
    });
    // A path is only a hint if it is what the context actually came from: a
    // rollout that resolved but yielded nothing must not leak one to a judge.
    if (t.msgs.length) {
      return {
        text: capped(t.msgs), source: "transcript",
        ...(t.transcriptPath ? { transcriptPath: t.transcriptPath } : {}),
      };
    }
  }
  const fallbackMax = opts.maxChars ?? (opts.recentKind === "rendered" ? maxChars : PTY_MAX_CHARS);
  return { text: stripAnsi(opts.recentPty).slice(-fallbackMax), source: "pty" };
}
