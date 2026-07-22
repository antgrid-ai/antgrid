import type { AgentItem, AgentError } from "../protocol";
import type { AgentUsageBreakdown } from "../structured/normalize";

// codex CommandExecutionStatus / PatchApplyStatus / McpToolCallStatus all use:
// "inProgress" | "completed" | "failed" | "declined".
function mapToolStatus(s: string | undefined): string {
  switch (s) {
    case "inProgress": return "running";
    case "completed": return "completed";
    case "failed": return "error";
    case "declined": return "error";
    default: return "pending";
  }
}

// codex CollabAgentStatus: pendingInit|running|interrupted|completed|errored|shutdown|notFound
function mapSubtaskStatus(s: string | undefined): string {
  switch (s) {
    case "inProgress":
    case "running":
    case "pendingInit": return "running";
    case "completed": return "completed";
    case "errored":
    case "failed": return "error";
    case "interrupted":
    case "shutdown":
    case "notFound": return "cancelled";
    default: return "running";
  }
}

// codex TurnPlanStepStatus: "pending" | "inProgress" | "completed".
export function mapPlanStepStatus(s: string | undefined): string {
  switch (s) {
    case "inProgress": return "running";
    case "completed": return "completed";
    default: return "pending";
  }
}

/** Map a codex TokenUsageBreakdown to our AgentUsage shape. */
export function mapTokenBreakdown(b: any): AgentUsageBreakdown {
  if (!b || typeof b !== "object") return {};
  return {
    totalTokens: b.totalTokens,
    inputTokens: b.inputTokens,
    outputTokens: b.outputTokens,
    cacheReadTokens: b.cachedInputTokens,
    reasoningTokens: b.reasoningOutputTokens,
  };
}

/** Map one codex v2 ThreadItem to a normalized AgentItem, or null if ignored. */
export function mapThreadItem(raw: any): AgentItem | null {
  if (!raw || typeof raw !== "object") return null;
  const itemId: string = raw.id ?? "";
  switch (raw.type) {
    case "agentMessage":
      return { itemId, kind: "message", role: "assistant", text: String(raw.text ?? "") };
    case "reasoning": {
      // codex carries reasoning in both summary[] and content[]; content is the
      // full text, summary the visible headline. Prefer content, fall back to
      // summary when content is empty (codex often populates only one).
      // content stays a plain "" join (single continuous stream); summary
      // parts are separate paragraphs, matching the live summaryPartAdded
      // separator, so those join with "\n\n".
      const content: string[] = Array.isArray(raw.content) ? raw.content : [];
      const summary: string[] = Array.isArray(raw.summary) ? raw.summary : [];
      const text = content.length > 0 ? content.join("") : summary.join("\n\n");
      return { itemId, kind: "reasoning", text };
    }
    case "commandExecution": {
      const item: AgentItem = {
        itemId, kind: "tool_call", toolKind: "shell",
        status: mapToolStatus(raw.status), title: String(raw.command ?? "shell"),
        rawInput: { command: raw.command, cwd: raw.cwd },
      };
      if (typeof raw.aggregatedOutput === "string" && raw.aggregatedOutput.length > 0) {
        item.content = [{ type: "terminal", data: raw.aggregatedOutput }];
      }
      return item;
    }
    case "fileChange": {
      const changes: any[] = Array.isArray(raw.changes) ? raw.changes : [];
      return {
        itemId, kind: "tool_call", toolKind: "edit",
        status: mapToolStatus(raw.status), title: "Edit files",
        content: changes.map((c) => ({ type: "diff" as const, path: String(c.path ?? ""), newText: String(c.diff ?? "") })),
      };
    }
    case "mcpToolCall":
      return {
        itemId, kind: "tool_call", toolKind: "mcp",
        status: mapToolStatus(raw.status), title: `${raw.server ?? ""}/${raw.tool ?? ""}`,
        rawInput: raw.arguments, rawOutput: raw.result ?? undefined,
      };
    case "plan":
      // The text-blob plan item is handled in the driver (folded into the same
      // synthetic plan:<turnId> item that turn/plan/updated drives), so the
      // structured step list wins over the blob. Ignored here to avoid a
      // duplicate plan row keyed by codex's own item id.
      return null;
    case "contextCompaction":
      return { itemId, kind: "compaction" };
    case "collabAgentToolCall": {
      // v1: render the collab tool-call itself as the subtask anchor.
      // codex emits receiver_thread_ids as an ARRAY (Vec<String>); the spawned
      // agent is the first entry. Fall back to the sender when none present.
      const receivers: string[] = Array.isArray(raw.receiverThreadIds) ? raw.receiverThreadIds : [];
      return {
        itemId, kind: "subtask",
        status: mapSubtaskStatus(raw.status),
        title: String(raw.tool ?? "subagent"),
        agent: receivers[0] ?? raw.senderThreadId,
      };
    }
    case "subAgentActivity":
      return {
        itemId, kind: "subtask", status: "running",
        title: String(raw.kind ?? "activity"), agent: raw.agentPath ?? raw.agentThreadId,
      };
    case "userMessage": {
      // codex's `text` part carries the user's literal message (mention/skill
      // spans are annotated in-place via text_elements); image/skill/mention
      // also arrive as discrete structured parts. Glue non-text parts with a
      // separating space and give references an `@` sigil so adjacent tokens
      // don't run together into an unreadable blob (was "reviewmain.rs"). Text
      // keeps its own internal spacing.
      const parts: any[] = Array.isArray(raw.content) ? raw.content : [];
      let text = "";
      const glue = (token: string) => {
        if (token.length === 0) return;
        if (text.length > 0 && !/\s$/.test(text)) text += " ";
        text += token;
      };
      for (const c of parts) {
        switch (c?.type) {
          case "text": text += String(c.text ?? ""); break;
          case "image":
          case "localImage": glue("[image]"); break;
          case "skill":
          case "mention": glue(`@${String(c.name ?? "")}`); break;
        }
      }
      return { itemId, kind: "message", role: "user", text: text.trimEnd() };
    }
    case "webSearch":
      return { itemId, kind: "tool_call", toolKind: "search", title: String(raw.query ?? "search") };
    case "imageView":
      return { itemId, kind: "tool_call", toolKind: "read", title: String(raw.path ?? "") };
    case "imageGeneration":
      return {
        itemId, kind: "tool_call", toolKind: "image",
        status: mapToolStatus(raw.status),
        title: typeof raw.revisedPrompt === "string" && raw.revisedPrompt.length > 0
          ? raw.revisedPrompt
          : "Generate image",
      };
    default:
      // Unknown kinds pass through so the app renders a generic row instead of
      // silently dropping the item. rawInput/rawOutput deliberately omitted —
      // arbitrary payloads are unbounded and this rides the relay path.
      return {
        itemId,
        kind: String(raw.type ?? "unknown"),
        ...(typeof raw.text === "string" ? { text: raw.text } : {}),
      };
  }
}

/** Map codex CodexErrorInfo (string enum or tagged object with a `type` key) to a normalized AgentError. */
export function mapCodexError(info: any, message: string): AgentError {
  // codex uses both plain string enums and tagged objects like { type: "serverOverloaded", httpStatusCode?: number }
  const tag: string = typeof info === "string" ? info : (info?.type ?? Object.keys(info ?? {})[0] ?? "other");
  const httpStatus: number | undefined =
    info && typeof info === "object" ? info.httpStatusCode : undefined;
  const byTag: Record<string, { category: AgentError["category"]; retryable: boolean }> = {
    contextWindowExceeded: { category: "context_overflow", retryable: false },
    usageLimitExceeded: { category: "quota_exceeded", retryable: false },
    serverOverloaded: { category: "server_error", retryable: true },
    internalServerError: { category: "server_error", retryable: true },
    unauthorized: { category: "auth", retryable: false },
    badRequest: { category: "unknown", retryable: false },
    httpConnectionFailed: { category: "network", retryable: true },
    sandboxError: { category: "unknown", retryable: false },
  };
  const mapped = byTag[tag] ?? { category: "unknown" as const, retryable: false };
  return {
    category: mapped.category,
    message,
    retryable: mapped.retryable,
    httpStatus: typeof httpStatus === "number" ? httpStatus : undefined,
    provider: "codex",
    raw: info,
  };
}

/** codex TurnStatus -> our turn-end stopReason. */
export function mapTurnStatusToStopReason(status: string): "end_turn" | "cancelled" | "error" {
  switch (status) {
    case "completed": return "end_turn";
    case "interrupted": return "cancelled";
    case "failed": return "error";
    default: return "end_turn";
  }
}
