import { join } from "node:path";
import { capEventText, forEachJsonlLine, userEvent, type HandoffEvent, type HandoffEventsFn } from "../handoff/events";

type Rec = Record<string, unknown>;

const isRecord = (value: unknown): value is Rec => typeof value === "object" && value !== null && !Array.isArray(value);

const USER_QUERY = /<user_query>([\s\S]*?)<\/user_query>/;
const CURSOR_COMMANDS = /^\s*<cursor_commands>[\s\S]*?<\/cursor_commands>\s*/;

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  if (value === undefined || value === null) return "";
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

function textParts(content: unknown): string[] {
  if (typeof content === "string") return [content];
  if (!Array.isArray(content)) return [];
  return content.filter(isRecord).flatMap((part) => (part.type === "text" && typeof part.text === "string" ? [part.text] : []));
}

/** Cursor wraps the typed prompt in `<user_query>`; every other user record is
 * injected context (`<user_info>`, rules, system reminders) and has no such tag. */
function userQuery(content: unknown): string | undefined {
  if (!Array.isArray(content)) return undefined;
  const queries = textParts(content)
    .map((text) => USER_QUERY.exec(text)?.[1]?.replace(CURSOR_COMMANDS, "").trim())
    .filter((text): text is string => !!text);
  return queries.length > 0 ? queries.join("\n") : undefined;
}

function cursorOptions(message: Rec): Rec {
  const options = isRecord(message.providerOptions) ? message.providerOptions.cursor : undefined;
  return isRecord(options) ? options : {};
}

function messageEvents(message: Rec, at: string): HandoffEvent[] {
  const options = cursorOptions(message);
  if (options.isSummary === true) {
    const summary = textParts(message.content).join("\n").trim();
    return summary ? [{ kind: "compaction", summary: capEventText(summary), at }] : [];
  }
  switch (message.role) {
    case "user": {
      const text = userQuery(message.content);
      return text ? [userEvent(text, at)] : [];
    }
    case "assistant": {
      if (typeof message.content === "string") {
        const text = message.content.trim();
        return text ? [{ kind: "assistant", text: capEventText(text), at }] : [];
      }
      if (!Array.isArray(message.content)) return [];
      const events: HandoffEvent[] = [];
      for (const part of message.content.filter(isRecord)) {
        if (part.type === "text" && typeof part.text === "string") {
          const text = part.text.trim();
          if (text) events.push({ kind: "assistant", text: capEventText(text), at });
        } else if (part.type === "tool-call" && typeof part.toolName === "string") {
          events.push({ kind: "tool_call", name: part.toolName, input: capEventText(stringify(part.args)), at });
        }
      }
      return events;
    }
    case "tool": {
      if (!Array.isArray(message.content)) return [];
      const high = isRecord(options.highLevelToolCallResult) ? options.highLevelToolCallResult : undefined;
      return message.content.filter(isRecord).flatMap((part): HandoffEvent[] => {
        if (part.type !== "tool-result") return [];
        const output = stringify(part.result) || stringify(high?.output);
        return [{
          kind: "tool_result",
          ...(typeof part.toolName === "string" ? { name: part.toolName } : {}),
          output: capEventText(output),
          at,
        }];
      });
    }
    default:
      return [];
  }
}

/** Reads the `cursor-chat.jsonl` the snapshot wrote: archived (pre-compaction)
 * messages first, then the live ones, so the order is chronological. */
export const cursorHandoffEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  await forEachJsonlLine(join(dir, manifest.primary), (lineNo, value) => {
    if (!isRecord(value)) return;
    const at = `${manifest.primary}:${lineNo}`;
    if (value.type === "summary_archive") {
      if (typeof value.summary === "string" && value.summary.trim()) {
        sink({ kind: "compaction", summary: capEventText(value.summary.trim()), at });
      }
    } else if (value.type === "message" && isRecord(value.message)) {
      for (const event of messageEvents(value.message, at)) sink(event);
    }
  }, signal);
};
