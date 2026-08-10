// bridge/src/handler/context.ts
import { agentSpec } from "../agents/registry";

// eslint-disable-next-line no-control-regex
const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;
export function stripAnsi(s: string): string { return s.replace(ANSI, ""); }

// How much history a decide call reasons over. PTY scrollback is noisy (prompts,
// ANSI, progress spam) so its fallback budget is capped independent of purpose.
export const DECIDE_MAX_CHARS = 12_000;
export const DECIDE_MAX_MSGS = 20;
export const PTY_MAX_CHARS = 8_000;

export async function assembleContext(opts: {
  tool: string; transcriptPath?: string; agentSessionId?: string; recentPty: string;
  // One tier today, still named rather than implied: the budgets below are
  // per-purpose, so a second caller has to state which tier it wants instead of
  // silently inheriting decide's.
  purpose: "decide"; maxChars?: number;
  // What `recentPty` actually holds. PTY_MAX_CHARS exists to cap NOISE (prompts,
  // ANSI, progress spam), which a chat session's rendered snapshot doesn't have —
  // applying it there silently pinned chat sessions to 8k regardless of the
  // purpose budget.
  recentKind?: "pty" | "rendered";
  // Test seams; production callers omit both.
  codexHome?: string; opencodeDbPath?: string;
}): Promise<{ text: string; source: "transcript" | "pty"; transcriptPath?: string }> {
  const maxChars = opts.maxChars ?? DECIDE_MAX_CHARS;
  const maxMsgs = DECIDE_MAX_MSGS;
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
