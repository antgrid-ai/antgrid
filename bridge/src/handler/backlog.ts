// bridge/src/handler/backlog.ts

// The live instruction stack. Collapsing the old Auditor role means the same
// evaluator call that says "run the tests" later says "tests ran", and that
// self-certification is only safe while the item vocabulary stays user-authored
// and finite. `applyTransitions` is where that bound is enforced (spec §2.1):
// the prompt restates it, but the prompt is the component being constrained.
//
// The §2.1 bound is unchanged by the citation gate below: `done` is still minted
// only by a transition naming a user-authored id, and nothing here can create
// one. What the gate narrows is WHEN — "carries an evidence field" means "cited
// something that is actually in the record the judge was shown", not merely "the
// string is not empty". It cannot tell a correct attribution from a real quote
// about the wrong subject; that judgement needs a reader, and
// the reader is the role that was collapsed. The command anchor is the one
// narrow substitute available without one.

import { z } from "zod";
import {
  MIN_EVIDENCE_CHARS,
  citationSegments,
  commandTokens,
  containsInOrder,
  normalizeForCitation,
} from "./evidence";

export const ItemStatus = z.enum(["queued", "active", "done", "blocked", "skipped", "failed"]);
export type ItemStatus = z.infer<typeof ItemStatus>;

export const InstructionItemSchema = z.object({
  id: z.string(),
  text: z.string(),
  dependsOn: z.array(z.string()).optional(),
  condition: z.string().optional(),
  status: ItemStatus,
  outcome: z.string().optional(),
  evidence: z.string().optional(),
  createdAt: z.number(),
});
export type InstructionItem = z.infer<typeof InstructionItemSchema>;

// Every function below resolves an id to at most one item, so a duplicate id
// leaves the shadowed copy unreachable by any transition and `allTerminal` false
// forever. Ids come from extraction, so uniqueness is checked at the boundary
// rather than assumed.
export const BacklogSchema = z.array(InstructionItemSchema).refine(
  (items) => new Set(items.map((i) => i.id)).size === items.length,
  { message: "duplicate item id" },
);

export const ItemTransitionSchema = z.object({
  id: z.string(),
  status: ItemStatus,
  evidence: z.string().optional(),
  outcome: z.string().optional(),
});
export type ItemTransition = z.infer<typeof ItemTransitionSchema>;

// Why a transition was refused, for callers that must act on the KIND rather
// than show the sentence. The engine surfaces the three evidence codes to the
// user and feeds them back into the next prompt; the other three are harness
// invariants a judge cannot usefully be taught around.
//
// The anchor has its own code because it is the one rule that can be UNSATISFIABLE
// rather than unsatisfied — see anchorTokens — so the engine has to count it
// separately from a citation the judge could simply have got right.
export type RejectionCode =
  | "malformed"
  | "unknown_id"
  | "already_terminal"
  | "missing_evidence"
  | "unverified_evidence"
  | "missing_command_anchor";

export interface TransitionResult {
  backlog: InstructionItem[];
  applied: { item: InstructionItem; from: ItemStatus; at: number }[];
  rejected: { transition: ItemTransition; reason: string; code: RejectionCode }[];
  // True only when an item REACHED `done`. This is the sole input to
  // guard.recordProgress(), which zeroes the consecutive-auto-reply cap, so a
  // finite backlog has to yield finite progress — which is what makes the
  // terminal states below a one-way door rather than a preference.
  progressed: boolean;
}

const TERMINAL: ReadonlySet<ItemStatus> = new Set<ItemStatus>(["done", "skipped", "failed"]);

/** §2.2's one-way door, asked about a single item. Exported so nothing outside
 *  re-lists the three statuses: a copy that drifts would let a caller act on an
 *  item this module considers closed. */
export function isTerminalStatus(status: ItemStatus): boolean {
  return TERMINAL.has(status);
}

// `dependsOn` is the one field an item shares by reference, so a shallow spread
// would hand the caller's array back out of a function documented as pure.
function cloneItem(i: InstructionItem): InstructionItem {
  return i.dependsOn ? { ...i, dependsOn: [...i.dependsOn] } : { ...i };
}

/** Whether a terminal transition's evidence is a citation, and — for `done` on an
 *  item that names a slash command — a citation about THAT command.
 *
 *  Both rules are deliberately blunt, because the alternative to a blunt
 *  deterministic rule here is a second model call grading the first one's
 *  homework. Grounding alone would not have caught the incident this exists for
 *  (the judge quoted a genuine sentence about a different review); the anchor is
 *  what catches that shape, and grounding is what stops the anchor being
 *  satisfied by simply typing the command name into the evidence field.
 *
 *  `normalizedCorpus` empty is not treated as "nothing is citable": a slot whose
 *  scrollback has not landed, or a chat render that failed, would otherwise have
 *  every terminal transition refused forever with the runaway guard as its only
 *  exit. Grounding is skipped there and the anchor is not, so an absent corpus
 *  fails toward the old behaviour rather than toward permanent refusal. */
function checkCitation(
  t: ItemTransition,
  item: InstructionItem,
  normalizedCorpus: string,
  ctx: TransitionContext,
): { reason: string; code: RejectionCode } | null {
  const raw = (t.evidence ?? "").trim();
  if (raw === "") return { reason: `${t.status} requires evidence`, code: "missing_evidence" };

  const quote = normalizeForCitation(raw);
  const segments = citationSegments(quote);
  const material = segments.join("").length;
  if (segments.length === 0 || material < MIN_EVIDENCE_CHARS) {
    return { reason: `${t.status} evidence is too short to be a quote`, code: "unverified_evidence" };
  }
  // The item's own line is the one string a judge can always produce without
  // having read anything, and renderBacklog puts it in the prompt — so quoting it
  // back is self-certification wearing a citation's clothes.
  if (quote === normalizeForCitation(item.text)) {
    return {
      reason: `${t.status} evidence only repeats the item's own text`,
      code: "unverified_evidence",
    };
  }
  if (normalizedCorpus.length >= MIN_EVIDENCE_CHARS && !containsInOrder(normalizedCorpus, segments)) {
    return {
      reason: `${t.status} evidence is not in the context you were shown — quote it exactly`,
      code: "unverified_evidence",
    };
  }
  // `done` only. A skip or a failure says the work did NOT happen, so demanding a
  // quote of the command being run would ask for the very record that does not
  // exist — and would make "correctly did not happen" unsayable again, which is
  // the §2.2 deadlock this whole vocabulary was widened to remove.
  if (t.status === "done" && !ctx.anchorWaived?.has(item.id)) {
    const tokens = anchorTokens(item, ctx);
    if (tokens.length > 0 && !tokens.some((tok) => quote.includes(tok))) {
      return {
        reason: `done needs evidence showing ${tokens[0]} itself being run`,
        code: "missing_command_anchor",
      };
    }
  }
  return null;
}

/** The slash-command tokens in an item's own text that this session could
 *  actually invoke.
 *
 *  `commandTokens` reads shape alone, and shape cannot tell a command from a
 *  route or a path segment in the user's own wording: "fix the /login redirect"
 *  yields `/login`, which no honest quote about that work will ever contain — so
 *  the anchor demands the impossible and the item can never close. A catalog is
 *  the one thing that can answer it, and it answers the same way checkReplyShape
 *  does: a verb the harness would refuse to send is not a command this session
 *  names.
 *
 *  An absent or EMPTY catalog means "none available" (a PTY, discovery that has
 *  not landed), never "this agent has none" — the same reading buildDecidePrompt
 *  and checkReplyShape take — so the anchor still applies there and the caller's
 *  `anchorWaived` is what keeps a false token from being permanent. */
function anchorTokens(item: InstructionItem, ctx: TransitionContext): string[] {
  const tokens = commandTokens(item.text);
  if (!ctx.commandNames?.length) return tokens;
  const names = new Set(ctx.commandNames.map((n) => n.toLowerCase().replace(/^\//, "")));
  return tokens.filter((tok) => names.has(tok.slice(1)));
}

/** What the judge was shown, and what this session can invoke. Every field is
 *  the caller's answer about THIS pass — none of it may be inferred here. */
export interface TransitionContext {
  evidenceCorpus: string;
  /** Command names as the catalog spells them (no leading slash required).
   *  Absent/empty = no catalog available for this session. */
  commandNames?: readonly string[];
  /** Items whose command anchor has been refused often enough that the caller
   *  has ruled the token unsatisfiable. Grounding still applies to them: what is
   *  waived is the demand for a token, never the demand for a real quote. */
  anchorWaived?: ReadonlySet<string>;
}

export function applyTransitions(
  backlog: InstructionItem[],
  transitions: ItemTransition[],
  now: number,
  // Required rather than optional: the one production call site has to answer
  // "what was the judge actually shown", and a default would let a future caller
  // inherit an unenforced gate in silence — the failure mode this gate exists to
  // end, one level up.
  ctx: TransitionContext,
): TransitionResult {
  // Normalizing 12k of context is cheap but not free, and most decisions carry no
  // terminal transition at all — so it is paid once, on the first one seen.
  let normalizedCorpus: string | undefined;
  const corpus = () => (normalizedCorpus ??= normalizeForCitation(ctx.evidenceCorpus));

  const next = backlog.map(cloneItem);
  const byId = new Map(next.map((i) => [i.id, i]));
  const applied: TransitionResult["applied"] = [];
  const rejected: TransitionResult["rejected"] = [];
  let progressed = false;

  for (const raw of transitions) {
    // Transitions arrive as JSON parsed from evaluator output, so the TS type is
    // a claim rather than a check. An unlisted status stored verbatim would never
    // match TERMINAL again, so the item could not be driven or wrapped up — the
    // deadlock §2.2 exists to remove.
    const parsed = ItemTransitionSchema.safeParse(raw);
    if (!parsed.success) {
      rejected.push({ transition: { ...raw }, reason: "malformed transition", code: "malformed" });
      continue;
    }
    const t = parsed.data;

    const item = byId.get(t.id);
    // No branch here may create an item: an evaluator that can mint an id can
    // mint progress. Rejections are returned rather than dropped so the engine
    // can log the attempt.
    if (!item) {
      rejected.push({ transition: t, reason: "unknown item id", code: "unknown_id" });
      continue;
    }
    // §2.2's terminal states are one-way. An evaluator able to walk an item back
    // out of `done` could re-complete it once per pass forever, resetting the
    // runaway guard every round — §2.1's mint-progress attack reached without
    // minting an id. Revival off `blocked` (non-terminal) stays open; reviving a
    // skipped item is a user tap in the backlog drawer (§4.3) — the wrap-up
    // summary is a push notification with no tap target — not an evaluator move.
    if (TERMINAL.has(item.status)) {
      rejected.push({ transition: t, reason: `${item.status} is terminal`, code: "already_terminal" });
      continue;
    }
    if (TERMINAL.has(t.status)) {
      const bad = checkCitation(t, item, corpus(), ctx);
      if (bad) {
        rejected.push({ transition: t, reason: bad.reason, code: bad.code });
        continue;
      }
    }
    const from = item.status;
    if (t.status === "done") progressed = true;
    item.status = t.status;
    // Evidence and outcome justify the status the item is in *now*, so a move
    // replaces them wholesale — a revived item carrying the reasoning that
    // blocked it reads as a fresh justification it does not have.
    item.evidence = t.evidence;
    item.outcome = t.outcome;
    applied.push({ item: cloneItem(item), from, at: now });
  }

  return { backlog: next, applied, rejected, progressed };
}

// Blocking is derived, never judged (§3.3): an item is blocked because a thing it
// depends on is, not because a model said so.
export function propagateBlocked(backlog: InstructionItem[]): InstructionItem[] {
  const next = backlog.map(cloneItem);
  const byId = new Map(next.map((i) => [i.id, i]));

  // Ids come from an LLM extraction pass, so the graph may contain a cycle and
  // nothing orders dependencies before their dependents. This is a fixpoint sweep
  // rather than a walk because it only ever moves an item toward `blocked`: at
  // most one change per item, so a cycle settles instead of recursing forever.
  let changed = true;
  while (changed) {
    changed = false;
    for (const item of next) {
      if (item.status === "blocked" || TERMINAL.has(item.status)) continue;
      const blocked = (item.dependsOn ?? []).some((id) => {
        const dep = byId.get(id);
        return dep !== undefined && (dep.status === "blocked" || dep.status === "failed");
      });
      if (blocked) {
        item.status = "blocked";
        changed = true;
      }
    }
  }
  return next;
}

export function nextActionable(backlog: InstructionItem[]): InstructionItem | undefined {
  const byId = new Map(backlog.map((i) => [i.id, i]));
  // `skipped` satisfies a dependency the way `done` does: it means the
  // precondition will not happen and did not fail (§3.3 propagates only
  // `blocked`/`failed`), so waiting on it would leave the dependent queued,
  // undrivable and non-terminal forever — mootness stranding work the user still
  // wants (§4.3). A dangling id is the opposite case: it reads as unsatisfied
  // rather than absent, because a precondition that was stated and then lost
  // cannot be checked, and surfacing unfinished work beats driving it blind.
  return backlog.find((i) => i.status === "queued" && (i.dependsOn ?? []).every((id) => {
    const dep = byId.get(id);
    return dep?.status === "done" || dep?.status === "skipped";
  }));
}

// Empty is deliberately NOT terminal: wrapping up an empty backlog ends a session
// that accomplished nothing, which §4.3 requires escalating instead.
export function allTerminal(backlog: InstructionItem[]): boolean {
  return backlog.length > 0 && backlog.every((i) => TERMINAL.has(i.status));
}

// Every field rendered into a prompt is extraction output, ids included, so any of
// them can carry a newline that would forge an extra list line — and a forged line
// hands the evaluator an id the user-authored vocabulary §2.1 rests on never
// contained. The ONE copy of that rule, here because this module imports nothing:
// the extraction prompt renders the same fields for the same reason, and
// reply-shape re-exports it for the engine's push bodies.
export function oneLine(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

/** Truncate to `max` UTF-16 code units without splitting an astral pair — the
 *  other half of the same rule, and here for the same reason.
 *
 *  `slice` cuts code units, so a cap landing between a surrogate pair strands a
 *  half that reaches the extractor's prompt and the app's activity feed alike as
 *  a replacement glyph. Every field clipped this way is user- or judge-authored,
 *  where an emoji at the cap is ordinary rather than exotic. */
export function clip(s: string, max: number, ellipsis = "…"): string {
  if (s.length <= max) return s;
  const last = s.charCodeAt(max - 1);
  const end = last >= 0xd800 && last <= 0xdbff ? max - 1 : max;
  return `${s.slice(0, end)}${ellipsis}`;
}

export function renderBacklog(backlog: InstructionItem[]): string {
  if (backlog.length === 0) return "(no items)";
  return backlog.map((i) => {
    // The evaluator answers with ids and nothing else, so the id leads every line.
    const parts = [`- id=${oneLine(i.id)} [${i.status}] ${oneLine(i.text)}`];
    if (i.dependsOn?.length) parts.push(`(depends on: ${i.dependsOn.map(oneLine).join(", ")})`);
    if (i.condition) parts.push(`(condition: ${oneLine(i.condition)})`);
    if (i.outcome) parts.push(`(outcome: ${oneLine(i.outcome)})`);
    return parts.join(" ");
  }).join("\n");
}

export function summarize(backlog: InstructionItem[]): {
  done: number; blocked: number; skipped: number; failed: number;
} {
  const count = (s: ItemStatus) => backlog.filter((i) => i.status === s).length;
  return {
    done: count("done"),
    blocked: count("blocked"),
    skipped: count("skipped"),
    failed: count("failed"),
  };
}
