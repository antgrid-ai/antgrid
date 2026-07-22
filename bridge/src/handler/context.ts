// bridge/src/handler/context.ts
import { messageText, readTranscriptTail } from "../transcript-tail";

// Mirrors title-resolver.ts JSONL iteration, but collects a rolling window of the
// last N message texts instead of title-specific fields. Every role is included:
// the handler needs conversation context, not just the agent's turn.
export async function readLastClaudeMessages(transcriptPath: string, n: number): Promise<string[]> {
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

export async function assembleContext(opts: {
  tool: string; transcriptPath?: string; recentPty: string; maxChars?: number;
}): Promise<{ text: string; source: "transcript" | "pty" }> {
  const maxChars = opts.maxChars ?? 4000;
  if (opts.tool === "claude-code" && opts.transcriptPath) {
    // codex/opencode intentionally use the PTY fallback below: no structured
    // transcript reader exists for them in v1.
    const msgs = await readLastClaudeMessages(opts.transcriptPath, 8);
    if (msgs.length) return { text: msgs.join("\n---\n").slice(-maxChars), source: "transcript" };
  }
  return { text: stripAnsi(opts.recentPty).slice(-maxChars), source: "pty" };
}
