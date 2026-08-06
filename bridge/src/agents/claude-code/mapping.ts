// Pure SDKMessage → agent:* mappers for the Claude Code driver. No SDK runtime
// imports — only plain-object transforms — so these unit-test in isolation
// (mirrors ../codex/mapping.ts).

import type { AgentError } from "../../protocol";
import { agentError } from "../../structured/agent-error";
import type { ToolKind } from "../../structured/tool-card";

type AbItemToolUse = { id: string; name: string; input: any };

export function mapToolKind(sdkToolName: string): ToolKind {
  if (sdkToolName.startsWith("mcp__")) return "mcp";
  switch (sdkToolName) {
    case "Bash": return "shell";
    case "Edit": case "Write": case "MultiEdit": case "NotebookEdit": return "edit";
    case "Read": case "NotebookRead": return "read";
    case "Glob": case "Grep": return "search";
    default: return "other";
  }
}

export function mapAssistantContent(blocks: any[]): {
  text: string; thinking: string; toolUses: AbItemToolUse[];
} {
  let text = "";
  let thinking = "";
  const toolUses: AbItemToolUse[] = [];
  for (const b of Array.isArray(blocks) ? blocks : []) {
    if (b?.type === "text" && typeof b.text === "string") text += b.text;
    else if (b?.type === "thinking" && typeof b.thinking === "string") thinking += b.thinking;
    else if (b?.type === "tool_use") toolUses.push({ id: String(b.id ?? ""), name: String(b.name ?? ""), input: b.input });
  }
  return { text, thinking, toolUses };
}

export interface ClaudeUsageTotals {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  totalTokens: number;
}

export function mapUsage(usage: any): ClaudeUsageTotals {
  const inputTokens = usage?.input_tokens ?? 0;
  const outputTokens = usage?.output_tokens ?? 0;
  return {
    inputTokens,
    outputTokens,
    cacheReadTokens: usage?.cache_read_input_tokens ?? 0,
    cacheWriteTokens: usage?.cache_creation_input_tokens ?? 0,
    totalTokens: inputTokens + outputTokens,
  };
}

// Accumulates per-turn usage into the session-cumulative total (see
// ClaudeDriver.usageTotal). Explicit per-field adds keep the shape checked at
// compile time instead of via a hand-maintained key array.
export function addUsage(total: ClaudeUsageTotals, delta: ClaudeUsageTotals): void {
  total.inputTokens += delta.inputTokens;
  total.outputTokens += delta.outputTokens;
  total.cacheReadTokens += delta.cacheReadTokens;
  total.cacheWriteTokens += delta.cacheWriteTokens;
  total.totalTokens += delta.totalTokens;
}

/** A rejecting `rate_limit_event` the driver saw before the failure. */
export interface ClaudeRateLimit {
  /** Epoch SECONDS, the unit the CLI emits (it renders `new Date(resetsAt * 1000)`). */
  resetsAt?: number;
  now: number;
}

// The result chunk itself never names the cause, so the caller supplies the
// rate-limit snapshot that arrived on the side channel; without one a failure
// stays deliberately coarse.
export function mapFailureError(message: string, limited?: ClaudeRateLimit): AgentError {
  if (!limited) return agentError({ category: "unknown", message, retryable: false });
  const retryAfterMs = limited.resetsAt !== undefined
    ? Math.max(0, limited.resetsAt * 1000 - limited.now)
    : undefined;
  return agentError({
    category: "rate_limited",
    message,
    retryable: true,
    ...(retryAfterMs !== undefined ? { retryAfterMs } : {}),
  });
}

export function mapResultError(chunk: any, limited?: ClaudeRateLimit): AgentError {
  // SDKResultError carries `errors: string[]` (no `result` field — that's
  // SDKResultSuccess only). Joining errors gives the actual failure reason
  // instead of the generic subtype fallback.
  const errors: string[] = Array.isArray(chunk?.errors) ? chunk.errors.filter(Boolean) : [];
  const msg = errors.length ? errors.join("; ") : `turn failed (${chunk?.subtype ?? "error"})`;
  return mapFailureError(msg, limited);
}
