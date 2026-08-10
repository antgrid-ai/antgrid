// bridge/src/handler/extract.ts

// One user sentence → the items Handler will track (spec §3). This pass reads the
// user's own words and nothing else — no transcript, no working tree — which is
// what keeps it extraction rather than the decomposition §3.1 leaves to the agent.

import { z } from "zod";
import { extractJsonObject } from "./json-extract";

// An item is one thing the user asked for, in their own words — a line, not a
// document. MAX_BACKLOG_ITEMS bounds how MANY items renderBacklog interpolates
// into every later decide prompt; this bounds how BIG each one is, and without
// both a single pasted spec starves the transcript budget the judge actually
// decides on. Over-cap output fails the parse rather than being trimmed: a
// sentence cut mid-word is an item nobody wrote, and the retry leg hands the
// extractor the rule back. The engine holds its raw fallback to the same bound.
export const MAX_ITEM_CHARS = 400;

// Deliberately NOT InstructionItemSchema: `id`, `status` and `createdAt` are the
// engine's to mint. `ref` is a batch-local label the extractor invents so items in
// one response can point at each other; an extractor that emitted final ids could
// reuse an id already in the backlog, and a duplicate id leaves the shadowed item
// unreachable by every transition (see backlog.ts).
export const ExtractedItemSchema = z.object({
  ref: z.string().min(1),
  text: z.string().min(1).max(MAX_ITEM_CHARS),
  dependsOn: z.array(z.string()).optional(),
  condition: z.string().max(MAX_ITEM_CHARS).optional(),
});
export type ExtractedItem = z.infer<typeof ExtractedItemSchema>;

const ExtractionResultSchema = z.object({ items: z.array(ExtractedItemSchema) });

// The instruction is untrusted user text and the prompt is a fixed budget, so the
// text cannot be allowed to crowd out the rules that constrain how it is read.
const MAX_INPUT_CHARS = 4_000;

// renderBacklog(backlog) is interpolated into EVERY subsequent buildDecidePrompt,
// so an unbounded backlog starves the decide prompt's context — and that failure
// surfaces as the supervisor making worse decisions, nowhere near this file.
// Over-cap output is truncated rather than rejected: some of what the user asked
// for beats none of it.
const MAX_ITEMS = 20;

// Nothing here re-sanitizes newlines in `text` or `condition`: renderBacklog runs
// oneLine() over every field it renders, and a second copy of that rule is a
// second place to keep in sync.
export function buildExtractPrompt(text: string): string {
  return [
    "You are a supervisor about to stand in for a user while a coding agent works.",
    "Split what the user just said into the separate items you will track on their behalf.",
    "",
    "THE USER'S INSTRUCTION:",
    text.slice(0, MAX_INPUT_CHARS),
    "",
    "WHAT AN ITEM IS:",
    "- One item per thing the USER asked for, phrased in their own words. You are splitting a sentence, not planning work.",
    "- NEVER break an item into the steps that achieve it. The coding agent does that, and it can see the repository while you can see only the sentence above.",
    '- "Run the tests" is ONE item. It is never "find the test command", "run it", "read the output".',
    `- Emit at most ${MAX_ITEMS} items. If the user asked for one thing, one item is the right answer.`,
    `- Keep each item's \`text\` (and \`condition\`) under ${MAX_ITEM_CHARS} characters. Quote the user; do not restate them at length.`,
    "",
    "DEPENDENCIES — the default is NONE:",
    '- Emit `dependsOn` ONLY when the instruction contains an explicit ordering word: "after", "then", "once X is done", "before", "when X is finished".',
    '- "and" is NOT an ordering word, and neither is the order the items happen to appear in.',
    '- "update the docs and run the tests" → two items, NEITHER depending on the other.',
    '- "run the tests after you update the docs" → the tests item depends on the docs item.',
    "- A dependency you invent silently blocks work the user wanted done; a dependency you omit only means the work is not made to wait. When the text gives no signal, omit it.",
    "",
    "REFS:",
    "- `ref` is a short label you invent for THIS response only, so one item can name another in `dependsOn`. It is discarded afterwards and is not an identifier of anything.",
    "- `dependsOn` may name ONLY refs that appear in this same response. Anything else is dropped.",
    "",
    "CONDITIONS:",
    '- `condition` holds what the user made an item conditional on: "if the build is red, file an issue" is one item, text "file an issue", condition "the build is red".',
    '- A condition is not a dependency: use `condition` for "if", `dependsOn` for "after" and "then".',
    "",
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    '{"items":[{"ref":"short-label","text":"what the user asked for","dependsOn":["another-ref"],"condition":"..."}]}',
  ].join("\n");
}

function withoutDependsOn(item: ExtractedItem): ExtractedItem {
  const { dependsOn: _dropped, ...rest } = item;
  return rest;
}

export function parseItemsFromOutput(stdout: string): { items: ExtractedItem[] | null; error?: string } {
  const obj = extractJsonObject(stdout);
  if (obj === null) return { items: null, error: "no JSON object found in output" };
  const parsed = ExtractionResultSchema.safeParse(obj);
  if (!parsed.success) return { items: null, error: parsed.error.message.slice(0, 500) };

  // Capping before refs are resolved is what makes truncation safe: a survivor
  // depending on a dropped item is left dangling, and the filter below removes it.
  const items = parsed.data.items.slice(0, MAX_ITEMS);
  // An empty backlog is never terminal (allTerminal), so a session armed on one
  // could never wrap up. Reported as an error so the caller retries and then falls
  // back to the raw instruction as a single item.
  if (items.length === 0) return { items: null, error: "no items extracted" };

  const refs = new Set(items.map((i) => i.ref));
  // Refs are batch-local by construction, so one naming anything outside this batch
  // names nothing at any later point. nextActionable reads a dangling dependency as
  // unsatisfied, so carrying it through would strand the item queued and
  // non-terminal forever; a self-reference strands it the same way.
  return {
    items: items.map((i) => {
      const deps = (i.dependsOn ?? []).filter((r) => r !== i.ref && refs.has(r));
      return deps.length > 0 ? { ...i, dependsOn: deps } : withoutDependsOn(i);
    }),
  };
}
