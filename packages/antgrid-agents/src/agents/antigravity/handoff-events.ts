import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  userEvent,
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

const stepOf = (value: Obj): number | undefined => (typeof value.step_index === "number" ? value.step_index : undefined);

/** Reads the untruncated transcript in file order, because `step_index` has
 * gaps and, after `/rewind`, repeats: agy keeps the retracted records and
 * writes the new pass under the same indices. The index is consulted only
 * where file order is known to lie, which is a tool result agy wrote before
 * the planner step that issued it. */
export const antigravityHandoffEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const pendingNames: string[] = [];
  // Results wait for the next record, which may be the planner that issued them.
  const held: Array<{ lineNo: number; value: Obj }> = [];
  // Highest step of the live pass so far. A planner above it is new work, so
  // results held with a higher step are its own; a user turn at or below it is
  // a rewind, which starts a new pass from that turn's step.
  let reached = -1;

  const emit = (lineNo: number, value: Obj) => {
    const at = `${manifest.primary}:${lineNo}`;
    const content = typeof value.content === "string" ? value.content : "";
    const step = stepOf(value);
    const rewound = value.type === "USER_INPUT" && value.source === "USER_EXPLICIT" && step !== undefined && step <= reached;
    // Keeping the retracted pass's high-water mark would read every later turn
    // of the new pass as another rewind until it outgrew the old one.
    if (step !== undefined) reached = rewound ? step : Math.max(reached, step);

    switch (value.type) {
      case "USER_INPUT": {
        if (value.source !== "USER_EXPLICIT") return;
        pendingNames.length = 0;
        if (rewound) {
          sink({ kind: "note", text: "Antigravity rewound the conversation here; the turns just above, back to the one this prompt replaces, were retracted and are no longer part of its live context.", at });
        }
        const text = requestText(content);
        if (!text) return;
        sink(userEvent(text, at));
        return;
      }
      case "PLANNER_RESPONSE": {
        if (content.trim()) sink({ kind: "assistant", text: capEventText(content), at });
        if (!Array.isArray(value.tool_calls)) return;
        // Results follow their own planner step, so a call that never got one
        // must not shift every later result onto the wrong name.
        pendingNames.length = 0;
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
  };

  const release = (keep: (value: Obj) => boolean = () => false) => {
    if (held.length === 0) return;
    const kept = held.filter(({ value }) => keep(value));
    for (const result of held) if (!keep(result.value)) emit(result.lineNo, result.value);
    held.splice(0, held.length, ...kept);
  };

  await forEachJsonlLine(
    join(dir, manifest.primary),
    (lineNo, value) => {
      if (!isObj(value)) return;
      if (value.type === "GENERIC") {
        held.push({ lineNo, value });
        if (held.length > PENDING_NAMES_MAX) emit(held[0]!.lineNo, held.shift()!.value);
        return;
      }
      const step = stepOf(value);
      if (value.type === "PLANNER_RESPONSE" && step !== undefined && step > reached) {
        release((result) => (stepOf(result) ?? -1) > step);
        emit(lineNo, value);
        release();
        return;
      }
      release();
      emit(lineNo, value);
    },
    signal,
  );
  release();
};
