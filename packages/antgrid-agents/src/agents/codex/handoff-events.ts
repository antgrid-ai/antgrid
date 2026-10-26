import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  isAntgridHandoffPrompt,
  userEvent,
  type HandoffEvent,
  type HandoffEventsFn,
} from "../handoff";
import { isInjectedUserText, replacementUserTexts, retainedTurns } from "./rollout-read";

// Codex wraps typed input in a template for some entry points; everything before
// this marker is scaffolding, not the user's words.
const USER_MESSAGE_BEGIN = "## My request for Codex:";
const MAX_RETAINED_USER_TEXTS = 3;

type Sink = (event: HandoffEvent) => void;
type Json = Record<string, unknown>;

const asRecord = (value: unknown): Json | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Json) : undefined;

/** A long message arrives split across several text parts that each carry
 * their own line breaks, so the parts are joined with nothing between them.
 * UserMessage spells the part type "text", AgentMessage "Text". */
function itemText(item: Json): string {
  if (!Array.isArray(item.content)) return "";
  let out = "";
  for (const part of item.content) {
    const record = asRecord(part);
    if (record && typeof record.text === "string" && String(record.type).toLowerCase() === "text") out += record.text;
  }
  return out;
}

function stripRequestWrapper(message: string): string {
  const index = message.indexOf(USER_MESSAGE_BEGIN);
  return (index >= 0 ? message.slice(index + USER_MESSAGE_BEGIN.length) : message).trim();
}

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === undefined || value === null) return "";
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

function commandText(command: unknown): string {
  return Array.isArray(command) ? command.map((part) => String(part)).join(" ") : stringify(command);
}

const isOwnUserText = (text: string) => !isInjectedUserText(text) && !isAntgridHandoffPrompt(text);

function retainedUserTexts(payload: Json): string[] {
  return replacementUserTexts(payload).filter((text) => !isAntgridHandoffPrompt(text)).slice(-MAX_RETAINED_USER_TEXTS);
}

/** Current checkpoints keep the recent turns of both sides in plaintext
 * retained_context; older ones only the user messages in replacement_history. */
function retainedSummary(payload: Json): string {
  const turns = retainedTurns(payload).filter((turn) => turn.role === "assistant" || isOwnUserText(turn.text));
  if (turns.length > 0) return turns.map((turn) => `${turn.role === "user" ? "User" : "Assistant"}: ${turn.text}`).join("\n\n");
  return retainedUserTexts(payload).map((text) => `User: ${text}`).join("\n\n");
}

function emitCompaction(record: Json, payload: Json, at: string, sink: Sink): void {
  const stamp = typeof record.timestamp === "string" ? record.timestamp : "an unknown time";
  const message = typeof payload.message === "string" ? payload.message.trim() : "";
  const summary = message || retainedSummary(payload);
  sink({ kind: "compaction", note: `compacted at ${stamp}; Codex encrypts its summary`, ...(summary ? { summary: capEventText(summary) } : {}), at });
}

function emitItem(item: Json, at: string, sink: Sink): void {
  switch (item.type) {
    case "UserMessage": {
      const text = stripRequestWrapper(itemText(item));
      if (!text) return;
      sink(userEvent(text, at));
      return;
    }
    case "AgentMessage": {
      const text = itemText(item).trim();
      if (text) sink({ kind: "assistant", text: capEventText(text), at });
      return;
    }
    case "Plan": {
      const text = typeof item.text === "string" ? item.text.trim() : "";
      if (text) sink({ kind: "assistant", text: capEventText(`Plan:\n${text}`), at });
      return;
    }
    case "CommandExecution": {
      sink({ kind: "tool_call", name: "shell", input: capEventText(commandText(item.command)), at });
      const output = typeof item.aggregated_output === "string" ? item.aggregated_output : "";
      const failed = typeof item.exit_code === "number" && item.exit_code !== 0;
      if (output || failed) {
        const suffix = failed ? `${output ? "\n" : ""}[exit code ${item.exit_code}]` : "";
        sink({ kind: "tool_result", name: "shell", output: capEventText(`${output}${suffix}`), ...(failed ? { isError: true } : {}), at });
      }
      return;
    }
    case "FileChange": {
      const changes = asRecord(item.changes);
      const paths = changes ? Object.keys(changes).join("\n") : stringify(item.changes);
      sink({ kind: "tool_call", name: "file change", input: capEventText(paths), at });
      return;
    }
    case "McpToolCall": {
      const name = [item.server, item.tool].filter((part) => typeof part === "string" && part).join(".") || "mcp";
      sink({ kind: "tool_call", name, input: capEventText(stringify(item.arguments)), at });
      const error = stringify(item.error);
      const result = asRecord(item.result);
      const output = error || stringify(item.result);
      if (output) {
        sink({ kind: "tool_result", name, output: capEventText(output), ...(error || result?.isError === true ? { isError: true } : {}), at });
      }
      return;
    }
    default:
      return;
  }
}

/** A turn that ended in an error (a usage limit is the common one) is the
 * reason the work stopped, which the continuing agent needs to know. */
function emitTurnError(payload: Json, at: string, sink: Sink): void {
  const error = asRecord(payload.error);
  if (!error) return;
  const code = stringify(error.codex_error_info);
  const message = typeof error.message === "string" ? error.message.trim() : "";
  if (!code && !message) return;
  const text = `The turn ended with an error${code ? ` (${code})` : ""}${message ? `: ${message}` : "."}`;
  sink({ kind: "assistant", text: capEventText(text), at });
}

function handleRecord(record: Json, at: string, sink: Sink): void {
  const payload = asRecord(record.payload);
  if (!payload) return;
  if (record.type === "compacted") {
    emitCompaction(record, payload, at, sink);
    return;
  }
  // The response_item twins duplicate these with injected context mixed in.
  if (record.type !== "event_msg") return;
  if (payload.type === "item_completed") {
    const item = asRecord(payload.item);
    if (item) emitItem(item, at, sink);
  } else if (payload.type === "user_message" && typeof payload.message === "string") {
    // Rollouts written before paginated history keep messages in these two events.
    const text = stripRequestWrapper(payload.message);
    if (text) sink(userEvent(text, at));
  } else if (payload.type === "agent_message" && typeof payload.message === "string") {
    const text = payload.message.trim();
    if (text) sink({ kind: "assistant", text: capEventText(text), at });
  } else if (payload.type === "task_complete") {
    emitTurnError(payload, at, sink);
  }
}

/** Reads the lineage root first, so the first genuine user message is the
 * thread's original task even when the leaf is a fork or a rollback. */
export const codexEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  for (const file of manifest.files) {
    if (file.role === "sidecar") continue;
    await forEachJsonlLine(
      join(dir, file.name),
      (lineNo, value) => {
        const record = asRecord(value);
        if (!record) return;
        try {
          handleRecord(record, `${file.name}:${lineNo}`, sink);
        } catch {
          // An unknown shape drops its event, never the whole excerpt.
        }
      },
      signal,
    );
  }
};
