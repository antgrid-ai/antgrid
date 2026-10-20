import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  isAntgridHandoffPrompt,
  type HandoffEventsFn,
} from "../handoff/events";

/** Bounds the id-to-name map; a result whose call is older than this loses its name only. */
const TOOL_NAME_MAP_MAX = 4_096;

type Obj = Record<string, unknown>;

const isObj = (value: unknown): value is Obj => typeof value === "object" && value !== null && !Array.isArray(value);

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

function errorText(error: unknown): string {
  if (isObj(error) && typeof error.message === "string") return error.message;
  return stringify(error);
}

/** Reads the copied event log. Subagent and skill-injected traffic is dropped
 * so the excerpt follows the main conversation only. */
export const copilotHandoffEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const names = new Map<string, string>();
  await forEachJsonlLine(
    join(dir, manifest.primary),
    (lineNo, value) => {
      if (!isObj(value) || !isObj(value.data) || value.agentId || value.data.parentToolCallId) return;
      const data = value.data;
      const at = `${manifest.primary}:${lineNo}`;

      switch (value.type) {
        case "user.message": {
          // `content` is what the person typed; `transformedContent` is the model-facing XML wrapping.
          if (data.source || data.isAutopilotContinuation || typeof data.content !== "string" || !data.content.trim()) return;
          sink({ kind: "user", text: capEventText(data.content), genuine: !isAntgridHandoffPrompt(data.content), at });
          return;
        }
        case "assistant.message": {
          if (typeof data.content === "string" && data.content.trim()) {
            sink({ kind: "assistant", text: capEventText(data.content), at });
          }
          return;
        }
        case "tool.execution_start": {
          if (typeof data.toolName !== "string") return;
          if (typeof data.toolCallId === "string") {
            if (names.size >= TOOL_NAME_MAP_MAX) names.delete(names.keys().next().value!);
            names.set(data.toolCallId, data.toolName);
          }
          sink({ kind: "tool_call", name: data.toolName, input: capEventText(stringify(data.arguments)), at });
          return;
        }
        case "tool.execution_complete": {
          const name = typeof data.toolCallId === "string" ? names.get(data.toolCallId) : undefined;
          const result = isObj(data.result) ? data.result.content : undefined;
          const failed = data.success === false;
          const output = result !== undefined ? stringify(result) : failed && data.error !== undefined ? errorText(data.error) : "";
          sink({ kind: "tool_result", ...(name ? { name } : {}), output: capEventText(output), ...(failed ? { isError: true } : {}), at });
          return;
        }
        case "session.compaction_complete": {
          if (data.success !== true) return;
          const summary = typeof data.summaryContent === "string" ? data.summaryContent.trim() : "";
          sink({ kind: "compaction", ...(summary ? { summary: capEventText(summary) } : {}), at });
          return;
        }
      }
    },
    signal,
  );
};
