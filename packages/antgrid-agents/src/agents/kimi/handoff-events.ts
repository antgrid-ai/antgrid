import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  userEvent,
  type HandoffEventsFn,
} from "../handoff/events";

type Rec = Record<string, unknown>;

const isRec = (value: unknown): value is Rec => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

/** Kimi has no sample on record, so every field is read defensively: its
 * generated manifest flattens `origin` to a string where the source writes an
 * object, and the parser accepts both. */
function originOf(record: Rec): { kind: string | undefined; trigger: string | undefined } {
  const origin = record.origin;
  if (typeof origin === "string") return { kind: origin, trigger: undefined };
  if (isRec(origin)) return { kind: str(origin.kind), trigger: str(origin.trigger) };
  return { kind: undefined, trigger: undefined };
}

/** An absent origin counts as the user's own. A skill or plugin command only
 * counts when the user typed the slash themselves. */
function isHumanOrigin(record: Rec): boolean {
  const { kind, trigger } = originOf(record);
  if (kind === undefined || kind === "user") return true;
  return (kind === "skill_activation" || kind === "plugin_command") && trigger === "user-slash";
}

function partsText(value: unknown): string {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return "";
  return value
    .map((part) => (typeof part === "string" ? part : isRec(part) && (part.type === undefined || part.type === "text") ? (str(part.text) ?? "") : ""))
    .join("");
}

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === undefined) return "";
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

/** The current shape of `summary` is a string; an older one is a context
 * message holding text parts. The sibling `contextSummary` is not used: its
 * footer names the original session path, which does not exist beside the copy. */
function compactionSummary(record: Rec): string | undefined {
  const summary = record.summary;
  const text = typeof summary === "string" ? summary : isRec(summary) ? partsText(summary.content) : "";
  return text.trim() ? text : undefined;
}

const MAX_TRACKED_CALLS = 500;

export const kimiEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const file = join(dir, manifest.primary);
  const callNames = new Map<string, string>();
  const rememberCall = (id: string | undefined, name: string) => {
    if (!id) return;
    if (callNames.size >= MAX_TRACKED_CALLS) callNames.delete(callNames.keys().next().value!);
    callNames.set(id, name);
  };
  await forEachJsonlLine(file, (lineNo, value) => {
    if (!isRec(value)) return;
    const at = `${manifest.primary}:${lineNo}`;
    switch (value.type) {
      // Kimi folds these and the loop events into one message list, so a message
      // is recorded one way or the other, never both. A live turn writes only
      // user-role ones (the prompt's mirror and system reminders), which
      // turn.prompt already covers; a session Kimi migrated from the Python
      // kimi-cli writes its whole history this way.
      case "context.append_message": {
        const message = value.message;
        if (!isRec(message)) return;
        if (message.role === "assistant") {
          const text = partsText(message.content).trim();
          if (text) sink({ kind: "assistant", text: capEventText(text), at });
          for (const call of Array.isArray(message.toolCalls) ? message.toolCalls : []) {
            if (!isRec(call)) continue;
            // The migration nests name and arguments under `function`; a live fold does not.
            const fn = isRec(call.function) ? call.function : call;
            const name = str(fn.name) ?? "tool";
            rememberCall(str(call.id), name);
            sink({ kind: "tool_call", name, input: capEventText(stringify(fn.arguments)), at });
          }
        } else if (message.role === "tool") {
          const id = str(message.toolCallId);
          const name = id ? callNames.get(id) : undefined;
          sink({
            kind: "tool_result",
            ...(name ? { name } : {}),
            output: capEventText(partsText(message.content) || stringify(message.content)),
            ...(message.isError === true ? { isError: true } : {}),
            at,
          });
        }
        return;
      }
      case "turn.prompt":
      case "turn.steer": {
        if (!isHumanOrigin(value)) return;
        const text = (typeof value.prompt === "string" ? value.prompt : partsText(value.input)).trim();
        if (!text) return;
        sink(userEvent(text, at));
        return;
      }
      case "context.apply_compaction": {
        const summary = compactionSummary(value);
        sink({ kind: "compaction", ...(summary ? { summary: capEventText(summary) } : { note: "Kimi compacted here but its summary was unreadable" }), at });
        return;
      }
      case "context.undo":
        sink({ kind: "note", text: "Kimi undid recent turns here; the turns just above may have been retracted and are no longer part of its live context.", at });
        return;
      case "context.clear":
        sink({ kind: "note", text: "Kimi cleared its context here; everything above, including the original task, is no longer live context.", at });
        return;
      case "context.append_loop_event": {
        const event = value.event;
        if (!isRec(event)) return;
        if (event.type === "content.part") {
          const part = event.part;
          if (!isRec(part) || part.type !== "text") return;
          const text = (str(part.text) ?? "").trim();
          if (text) sink({ kind: "assistant", text: capEventText(text), at });
        } else if (event.type === "tool.call") {
          const name = str(event.name) ?? "tool";
          rememberCall(str(event.toolCallId), name);
          sink({ kind: "tool_call", name, input: capEventText(stringify(event.args)), at });
        } else if (event.type === "tool.result") {
          const result = isRec(event.result) ? event.result : {};
          const id = str(event.toolCallId);
          const name = id ? callNames.get(id) : undefined;
          sink({
            kind: "tool_result",
            ...(name ? { name } : {}),
            output: capEventText(partsText(result.output) || stringify(result.output)),
            ...(result.isError === true ? { isError: true } : {}),
            at,
          });
        }
        return;
      }
    }
  }, signal);
};
