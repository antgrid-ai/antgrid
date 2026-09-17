import type { AgentItem, AgentError } from "../../protocol";
import type { AgentUsageBreakdown } from "../../structured/normalize";
import { agentError, byName, type ErrorClass } from "../../structured/agent-error";
import {
  compaction, message as messageItem, reasoning, toolCall, toolOutput,
  type PlanStatus, type ToolKind, type ToolStatus,
} from "../../structured/tool-card";

/** opencode builtin tool name -> normalized toolKind. */
export function toolKind(name: string): ToolKind {
  switch (name) {
    case "bash":
    case "shell": return "shell";
    case "edit":
    case "write":
    case "patch": return "edit";
    case "read": return "read";
    case "webfetch":
    case "fetch": return "fetch";
    case "grep":
    case "glob":
    case "list":
    case "ls": return "search";
    case "task": return "task";
    // MCP tools are namespaced "<server>_<tool>"; bare builtins are not.
    default: return name.includes("_") ? "mcp" : "other";
  }
}

function mapToolStatus(s: string | undefined): ToolStatus {
  switch (s) {
    case "pending": return "pending";
    case "running": return "running";
    case "completed": return "completed";
    case "error": return "error";
    default: return "pending";
  }
}

// opencode todo status: pending | in_progress | completed | cancelled.
function mapTodoStatus(s: string | undefined): PlanStatus {
  switch (s) {
    case "in_progress": return "running";
    case "completed": return "completed";
    case "cancelled": return "cancelled";
    default: return "pending";
  }
}

export function mapPlanEntries(todos: unknown): Array<{ text: string; status: PlanStatus }> {
  return (Array.isArray(todos) ? todos : []).map((t: any) => ({
    text: String(t?.content ?? ""),
    status: mapTodoStatus(t?.status),
  }));
}

/** opencode AssistantMessage.tokens -> our AgentUsage breakdown. */
export function mapTokens(tokens: any): AgentUsageBreakdown {
  if (!tokens || typeof tokens !== "object") return {};
  // input + output + cache.read + cache.write.
  const totalTokens = typeof tokens.total === "number"
    ? tokens.total
    : (tokens.input ?? 0) + (tokens.output ?? 0) + (tokens.cache?.read ?? 0) + (tokens.cache?.write ?? 0);
  return {
    totalTokens,
    inputTokens: tokens.input,
    outputTokens: tokens.output,
    reasoningTokens: tokens.reasoning,
    cacheReadTokens: tokens.cache?.read,
  };
}

// opencode NamedError: { name, data:{ message? } } (or a bare string).
const ERROR_BY_NAME: Record<string, ErrorClass> = {
  ProviderAuthError: { category: "auth", retryable: false },
  MessageAbortedError: { category: "aborted", retryable: false },
  MessageOutputLengthError: { category: "context_overflow", retryable: false },
};

export function mapOpencodeError(err: any): AgentError {
  const name: string = typeof err === "string" ? err : (err?.name ?? "unknown");
  const message: string =
    (err && typeof err === "object" ? (err.data?.message ?? err.message) : undefined) ??
    (typeof err === "string" ? err : "agent error");
  const mapped = byName(ERROR_BY_NAME, name);
  return agentError({
    category: mapped.category, message, retryable: mapped.retryable, provider: "opencode", raw: err,
  });
}

/** Map one opencode message Part to a normalized AgentItem, or null if ignored. */
export function mapPart(part: any, role: "assistant" | "user" = "assistant"): AgentItem | null {
  if (!part || typeof part !== "object") return null;
  const itemId: string = part.id ?? "";
  switch (part.type) {
    case "text":
      return messageItem({
        itemId,
        role,
        text: String(part.text ?? ""),
        ...(part.messageID ? { revertTarget: { messageId: String(part.messageID), partId: itemId } } : {}),
      });
    case "reasoning":
      return reasoning({ itemId, text: String(part.text ?? "") });
    case "tool": {
      const kind = toolKind(String(part.tool ?? ""));
      const state = part.state ?? {};
      return toolCall({
        itemId, toolKind: kind,
        status: mapToolStatus(state.status),
        title: String(state.title ?? part.tool ?? "tool"),
        rawInput: state.input,
        ...(state.status === "completed" && typeof state.output === "string"
          ? { content: toolOutput(kind, state.output) }
          : {}),
        ...(state.status === "error" ? { error: mapOpencodeError(state.error) } : {}),
      });
    }
    case "patch": {
      // PatchPart carries changed file paths, not diff text (the diff body is not
      // on the event); emit a per-file diff stub so the UI lists the touched files.
      const files: string[] = Array.isArray(part.files) ? part.files : [];
      return toolCall({
        itemId, toolKind: "edit", status: "completed", title: "Edit files",
        content: files.map((f) => ({ type: "diff" as const, path: String(f), newText: "" })),
      });
    }
    case "compaction":
      return compaction({ itemId });
    default:
      // file (attachment), agent, subtask, step-start/finish, snapshot, retry:
      // subtask is handled via session.created; the rest are not v1 item kinds.
      return null;
  }
}
