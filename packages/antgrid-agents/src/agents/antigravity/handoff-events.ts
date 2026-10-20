import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  isAntgridHandoffPrompt,
  type HandoffEventsFn,
} from "../handoff/events";

const USER_REQUEST = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/;
/** Blocks agy appends to a prompt that the person did not write. */
const INJECTED_BLOCK = /<(ADDITIONAL_METADATA|USER_SETTINGS_CHANGE|PLAN)>[\s\S]*?<\/\1>/g;
/** Every tool result opens with these timing lines. */
const RESULT_HEADER = /^Created At:[^\n]*\n(?:Completed At:[^\n]*\n)?/;
/** Results carry no call id, so they pair by order; a runaway of calls with no results stays bounded. */
const PENDING_NAMES_MAX = 64;

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

function requestText(content: string): string {
  const wrapped = USER_REQUEST.exec(content)?.[1];
  return (wrapped ?? content.replace(INJECTED_BLOCK, "")).trim();
}

/** Reads the untruncated transcript in file order: `step_index` has gaps and
 * duplicates, so it is never used for ordering. */
export const antigravityHandoffEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const pendingNames: string[] = [];
  await forEachJsonlLine(
    join(dir, manifest.primary),
    (lineNo, value) => {
      if (!isObj(value)) return;
      const at = `${manifest.primary}:${lineNo}`;
      const content = typeof value.content === "string" ? value.content : "";

      switch (value.type) {
        case "USER_INPUT": {
          if (value.source !== "USER_EXPLICIT") return;
          const text = requestText(content);
          if (!text) return;
          sink({ kind: "user", text: capEventText(text), genuine: !isAntgridHandoffPrompt(text), at });
          return;
        }
        case "PLANNER_RESPONSE": {
          if (content.trim()) sink({ kind: "assistant", text: capEventText(content), at });
          if (!Array.isArray(value.tool_calls)) return;
          for (const call of value.tool_calls) {
            if (!isObj(call) || typeof call.name !== "string") continue;
            if (pendingNames.length < PENDING_NAMES_MAX) pendingNames.push(call.name);
            sink({ kind: "tool_call", name: call.name, input: capEventText(stringify(call.args)), at });
          }
          return;
        }
        case "GENERIC": {
          const name = pendingNames.shift();
          const failed = value.status === "ERROR";
          const body = content.replace(RESULT_HEADER, "");
          const output = failed && typeof value.error === "string" ? [body, value.error].filter(Boolean).join("\n") : body;
          sink({ kind: "tool_result", ...(name ? { name } : {}), output: capEventText(output), ...(failed ? { isError: true } : {}), at });
          return;
        }
        case "CHECKPOINT": {
          const summary = content.trim();
          sink({ kind: "compaction", ...(summary ? { summary: capEventText(summary) } : {}), at });
          return;
        }
      }
    },
    signal,
  );
};
