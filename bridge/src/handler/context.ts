// bridge/src/handler/context.ts
import { messageText, readTranscriptTail } from "../transcript-tail";
import { findCodexRolloutPath, readLastCodexMessages } from "../codex/codex-rollout-read";
import { readLastOpencodeMessages } from "../opencode/opencode-db-read";

// Mirrors title-resolver.ts JSONL iteration, but collects a rolling window of the
// last N message texts instead of title-specific fields. Every role is included:
// the handler needs conversation context, not just the agent's turn.
export async function readLastClaudeMessages(transcriptPath: string, n: number): Promise<string[]> {
  if (n <= 0) return []; // slice(-0) === slice(0) — the whole array, not none
  const raw = await readTranscriptTail(transcriptPath);
  if (!raw) return [];
  const out: string[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    try {
      const obj = JSON.parse(line);
      const text = messageText(obj?.message?.content);
      if (text) out.push(text);
    } catch { /* skip malformed line */ }
  }
  return out.slice(-n);
}

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
  if (opts.tool === "claude-code" && opts.transcriptPath) {
    const msgs = await readLastClaudeMessages(opts.transcriptPath, maxMsgs);
    if (msgs.length) return { text: capped(msgs), source: "transcript", transcriptPath: opts.transcriptPath };
  }
  if (opts.tool === "codex" && opts.agentSessionId) {
    const path = await findCodexRolloutPath(opts.agentSessionId, opts.codexHome);
    if (path) {
      const msgs = await readLastCodexMessages(path, maxMsgs);
      if (msgs.length) return { text: capped(msgs), source: "transcript", transcriptPath: path };
    }
  }
  if (opts.tool === "opencode" && opts.agentSessionId) {
    // No transcriptPath out: a SQLite DB is not a followable file hint for a judge.
    const msgs = readLastOpencodeMessages(opts.agentSessionId, maxMsgs, opts.opencodeDbPath);
    if (msgs.length) return { text: capped(msgs), source: "transcript" };
  }
  const fallbackMax = opts.maxChars ?? (opts.recentKind === "rendered" ? maxChars : PTY_MAX_CHARS);
  return { text: stripAnsi(opts.recentPty).slice(-fallbackMax), source: "pty" };
}
