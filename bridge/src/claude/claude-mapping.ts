// Pure SDKMessage → agent:* mappers for the Claude Code driver. No SDK runtime
// imports — only plain-object transforms — so these unit-test in isolation
// (mirrors codex-mapping.ts).

type AbItemToolUse = { id: string; name: string; input: any };

export function mapToolKind(sdkToolName: string): string {
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

export interface ClaudeTurnError {
  category: "unknown";
  message: string;
  retryable: false;
}

export function mapResultError(chunk: any): ClaudeTurnError {
  // SDKResultError carries `errors: string[]` (no `result` field — that's
  // SDKResultSuccess only). Joining errors gives the actual failure reason
  // instead of the generic subtype fallback.
  const errors: string[] = Array.isArray(chunk?.errors) ? chunk.errors.filter(Boolean) : [];
  const msg = errors.length ? errors.join("; ") : `turn failed (${chunk?.subtype ?? "error"})`;
  // The SDK result subtype is coarse (error_max_turns, error_during_execution);
  // there's no fine-grained category on the result chunk, so classify as unknown
  // and non-retryable. Auth/rate-limit surface earlier via assistant.error.
  return { category: "unknown", message: msg, retryable: false };
}
