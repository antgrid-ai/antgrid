import { join } from "node:path";
import {
  capEventText,
  forEachJsonlLine,
  isAntgridHandoffPrompt,
  type HandoffEventsFn,
} from "../handoff/events";

/** Wrapper tags Claude puts around records that are not something the user typed. */
const NOISE_PREFIX = /^\s*(?:<(?:command-name|command-message|local-command-[a-z]+|task-notification|bash-[a-z]+|system-reminder)[\s>]|\[Request interrupted)/;
const COMMAND_ARGS = /<command-args>([\s\S]*?)<\/command-args>/;
const COMMAND_WRAPPER = /^\s*<command-(?:name|message|args)[\s>]/;
/** Bounds the id-to-name map; a result whose call is older than this loses its name only. */
const TOOL_NAME_MAP_MAX = 4_096;

type Obj = Record<string, unknown>;

const isObj = (value: unknown): value is Obj => typeof value === "object" && value !== null && !Array.isArray(value);

function partText(part: unknown): string {
  return isObj(part) && part.type === "text" && typeof part.text === "string" ? part.text : "";
}

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.map(partText).join("") : "";
}

/** A slash or skill prompt keeps the user's words inside `<command-args>`; any
 * other wrapper-led text is not the user's task. */
function userText(raw: string): string | undefined {
  const text = raw.trim();
  if (!text) return undefined;
  if (COMMAND_WRAPPER.test(text)) {
    const args = COMMAND_ARGS.exec(text)?.[1]?.trim();
    return args || undefined;
  }
  return NOISE_PREFIX.test(text) ? undefined : text;
}

function stringify(value: unknown): string {
  if (typeof value === "string") return value;
  try {
    return JSON.stringify(value) ?? "";
  } catch {
    return "";
  }
}

/** Reads the copied transcript: its own `toolUseResult` twin is never read,
 * because that structured copy is what makes single lines megabytes long. */
export const claudeHandoffEvents: HandoffEventsFn = async (dir, manifest, sink, signal) => {
  const names = new Map<string, string>();
  await forEachJsonlLine(
    join(dir, manifest.primary),
    (lineNo, value) => {
      if (!isObj(value) || value.isSidechain === true) return;
      const at = `${manifest.primary}:${lineNo}`;
      const message = isObj(value.message) ? value.message : undefined;
      const content = message?.content;

      if (value.type === "assistant") {
        if (!Array.isArray(content)) return;
        for (const part of content) {
          if (!isObj(part)) continue;
          if (part.type === "text" && typeof part.text === "string" && part.text.trim()) {
            sink({ kind: "assistant", text: capEventText(part.text), at });
          } else if (part.type === "tool_use" && typeof part.name === "string") {
            if (typeof part.id === "string") {
              if (names.size >= TOOL_NAME_MAP_MAX) names.delete(names.keys().next().value!);
              names.set(part.id, part.name);
            }
            sink({ kind: "tool_call", name: part.name, input: capEventText(stringify(part.input)), at });
          }
        }
        return;
      }
      if (value.type !== "user") return;

      if (value.isCompactSummary === true) {
        const summary = contentText(content).trim();
        sink({ kind: "compaction", ...(summary ? { summary: capEventText(summary) } : {}), at });
        return;
      }
      if (value.isMeta === true) return;

      if (Array.isArray(content) && content.some((part) => isObj(part) && part.type === "tool_result")) {
        for (const part of content) {
          if (!isObj(part) || part.type !== "tool_result") continue;
          const name = typeof part.tool_use_id === "string" ? names.get(part.tool_use_id) : undefined;
          sink({
            kind: "tool_result",
            ...(name ? { name } : {}),
            output: capEventText(contentText(part.content)),
            ...(part.is_error === true ? { isError: true } : {}),
            at,
          });
        }
        return;
      }

      // Records without an origin predate the field and were typed by a person.
      if (isObj(value.origin) && value.origin.kind !== "human") return;
      const text = userText(contentText(content));
      if (text === undefined) return;
      sink({ kind: "user", text: capEventText(text), genuine: !isAntgridHandoffPrompt(text), at });
    },
    signal,
  );
};
