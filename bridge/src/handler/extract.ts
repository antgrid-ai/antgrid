// bridge/src/handler/extract.ts

// One user sentence → the items Handler will track. This pass reads the user's
// own words and the list already kept from them, and nothing else — no
// transcript, no working tree — which is what keeps it extraction rather than
// the decomposition this pass leaves to the agent. The list is there so one
// sentence can take an earlier one back; every id it names is checked against
// the live backlog by the engine afterwards, never trusted from here.

import { z } from "zod";
import { clip, isTerminalStatus, oneLine, type InstructionItem } from "./backlog";
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

// The other half of what one sentence can say. `items` stays append-only — the
// id-collision reasoning above rests on the extractor never naming a final id —
// so taking something back is a SEPARATE array that names ids the extractor was
// shown, and the engine applies it against the backlog as it stands.
//
// There is deliberately no `status` field, at any value: a change of mind is not
// evidence of work, and a terminal status minted from the user's words alone
// would route around the citation gate applyTransitions exists to hold. `drop`
// is a removal for the same reason — see applyAmendments.
export const AmendmentSchema = z.object({
  id: z.string().min(1),
  action: z.enum(["drop", "revise"]),
  text: z.string().min(1).max(MAX_ITEM_CHARS).optional(),
  // Empty is meaningful and `text` empty is not: "do it regardless" clears the
  // gate an earlier sentence put on an item, and absent has to keep meaning
  // "leave it alone" or every reword would silently wipe one.
  condition: z.string().max(MAX_ITEM_CHARS).optional(),
});
export type Amendment = z.infer<typeof AmendmentSchema>;

const ExtractionResultSchema = z.object({
  // Defaulted rather than required, because the drop-only answer the prompt asks
  // for — `{"amend":[{"id":"i1","action":"drop"}]}` — is the one an extractor is
  // most likely to send without an empty `items` beside it. Required, that
  // response failed the whole parse and fell through to the raw fallback, which
  // lands "actually skip the commit" as an item no transcript can ever close: the
  // exact deadlock amendments exist to end. The both-empty guard below still
  // reports an unrelated JSON object as a failed extraction.
  items: z.array(ExtractedItemSchema).default([]),
  amend: z.array(AmendmentSchema).optional(),
});

export interface ExtractionResult {
  items: ExtractedItem[];
  amend: Amendment[];
}

// The instruction is untrusted user text and the prompt is a fixed budget, so the
// text cannot be allowed to crowd out the rules that constrain how it is read.
const MAX_INPUT_CHARS = 4_000;

// renderBacklog(backlog) is interpolated into EVERY subsequent buildDecidePrompt,
// so an unbounded backlog starves the decide prompt's context — and that failure
// surfaces as the supervisor making worse decisions, nowhere near this file.
// Over-cap output is truncated rather than rejected: some of what the user asked
// for beats none of it.
const MAX_ITEMS = 20;

// How many open items the extractor is shown, and — because it cannot honestly
// name an id it was never given — how many amendments it may send back. A backlog
// holds up to MAX_BACKLOG_ITEMS of up to MAX_ITEM_CHARS each, which is ten times
// the budget the instruction itself gets, so the list is bounded twice: closed
// items are left out entirely (nothing here may reopen one), and what remains is
// clipped to the length that identifies a line rather than reproduces it.
const MAX_AMENDABLE_ITEMS = 30;
const MAX_AMENDABLE_LINE_CHARS = 120;

/** The items an amendment may name: the open ones, under the cap
 *  renderAmendable shows them at.
 *
 *  The engine resolves against this rather than against the whole backlog,
 *  because everything past the cap is announced to the extractor as "not
 *  changeable" and an id it was never given can only have been guessed — and
 *  these ids end in a dense integer (`item-<projectId>-<now>-<seq>`), so
 *  extrapolating one past the end of a list it has just been told is truncated
 *  is a completion an LLM makes readily. */
export function amendableItems(backlog: InstructionItem[]): InstructionItem[] {
  return backlog.filter((i) => !isTerminalStatus(i.status)).slice(0, MAX_AMENDABLE_ITEMS);
}

/** The open backlog as the extractor may address it, or null when there is
 *  nothing it could amend — an arm-time pass, or a session whose every item is
 *  closed. Callers omit the whole amendment block on null: rules about ids, with
 *  no ids under them, are an invitation to invent one. */
export function renderAmendable(backlog: InstructionItem[]): string | null {
  const open = backlog.filter((i) => !isTerminalStatus(i.status));
  if (open.length === 0) return null;
  const shown = amendableItems(backlog);
  const lines = shown.map(
    (i) => `- id=${oneLine(i.id)} [${i.status}] ${clip(oneLine(i.text), MAX_AMENDABLE_LINE_CHARS, "...")}`,
  );
  const hidden = open.length - shown.length;
  // Said rather than left silent: an extractor that reads the list as complete
  // answers "there is no commit item" by inventing one.
  if (hidden > 0) lines.push(`(and ${hidden} more, not shown here and not changeable)`);
  return lines.join("\n");
}

// Nothing here re-sanitizes newlines in `text` or `condition`: renderBacklog runs
// oneLine() over every field it renders, and a second copy of that rule is a
// second place to keep in sync.
export function buildExtractPrompt(text: string, backlog: InstructionItem[] = []): string {
  const amendable = renderAmendable(backlog);
  return [
    "You are a supervisor about to stand in for a user while a coding agent works.",
    "Split what the user just said into the separate items you will track on their behalf.",
    "",
    "THE USER'S INSTRUCTION:",
    text.slice(0, MAX_INPUT_CHARS),
    "",
    ...(amendable ? ["WHAT YOU ARE ALREADY TRACKING FOR THEM:", amendable, ""] : []),
    "WHAT AN ITEM IS:",
    "- One item per thing the USER asked for, phrased in their own words. You are splitting a sentence, not planning work.",
    "- NEVER break an item into the steps that achieve it. The coding agent does that, and it can see the repository while you cannot.",
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
    ...(amendable ? [
      "TAKING SOMETHING BACK:",
      "- When the user is cancelling or rewriting something you are ALREADY tracking, say so in `amend` against that item's `id`. Do NOT also emit an item about it.",
      '- "actually skip the commit" is not a new thing to do. It is `{"id":"<the commit item>","action":"drop"}` and NO item.',
      '- "make that the full suite, not just the unit tests" is `{"id":"<the tests item>","action":"revise","text":"run the full test suite"}`.',
      '- `revise` carries `text`, or `condition`, or both. Omit a field to leave it as it is; send `"condition":""` to drop a condition the user no longer wants.',
      "- Copy `id` EXACTLY from the list above. An id that is not on that list is ignored, and so is anything about an item that is not.",
      "- You CANNOT mark anything done, skipped or failed here. Those are read from what the agent actually did, never from what the user says.",
      '- A sentence that only takes something back has no items at all: "items":[].',
      "",
    ] : []),
    "Respond with ONLY a single JSON object, no prose, matching exactly:",
    amendable
      ? '{"items":[{"ref":"short-label","text":"what the user asked for","dependsOn":["another-ref"],"condition":"..."}],"amend":[{"id":"an-id-from-the-list","action":"drop"}]}'
      : '{"items":[{"ref":"short-label","text":"what the user asked for","dependsOn":["another-ref"],"condition":"..."}]}',
  ].join("\n");
}

function withoutDependsOn(item: ExtractedItem): ExtractedItem {
  const { dependsOn: _dropped, ...rest } = item;
  return rest;
}

export function parseExtractionOutput(stdout: string): {
  items: ExtractedItem[] | null;
  amend: Amendment[];
  error?: string;
} {
  const obj = extractJsonObject(stdout);
  if (obj === null) return { items: null, amend: [], error: "no JSON object found in output" };
  const parsed = ExtractionResultSchema.safeParse(obj);
  if (!parsed.success) return { items: null, amend: [], error: parsed.error.message.slice(0, 500) };

  // Capping before refs are resolved is what makes truncation safe: a survivor
  // depending on a dropped item is left dangling, and the filter below removes it.
  const items = parsed.data.items.slice(0, MAX_ITEMS);
  const amend = takeAmendments(parsed.data.amend ?? []);
  // An empty backlog is never terminal (allTerminal), so a session armed on one
  // could never wrap up. Reported as an error so the caller retries and then falls
  // back to the raw instruction as a single item. An amendment is a different
  // answer, not a missing one: "actually skip the commit" is correctly no items,
  // and landing the sentence as an item is the deadlock it was undoing.
  if (items.length === 0 && amend.length === 0) {
    return { items: null, amend: [], error: "no items extracted" };
  }

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
    amend,
  };
}

/** Shape rules about the response, ahead of anything about the backlog: whether
 *  an id names a live item is the engine's question, asked after the await
 *  against the list as it then stands.
 *
 *  One id, one amendment. Two entries naming the same item are the extractor
 *  contradicting itself, and the first is the one the rest of the response was
 *  written around — the same "first occurrence wins" the ref table takes. */
function takeAmendments(raw: Amendment[]): Amendment[] {
  const seen = new Set<string>();
  const kept: Amendment[] = [];
  for (const a of raw) {
    if (kept.length >= MAX_AMENDABLE_ITEMS) break;
    if (seen.has(a.id)) continue;
    // A revise that revises nothing would still cost the user a feed row saying
    // their list changed when it did not.
    if (a.action === "revise" && a.text === undefined && a.condition === undefined) continue;
    seen.add(a.id);
    kept.push(a.action === "drop" ? { id: a.id, action: "drop" } : a);
  }
  return kept;
}
