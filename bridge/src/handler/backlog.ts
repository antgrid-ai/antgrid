// bridge/src/handler/backlog.ts

// The live instruction stack. Collapsing the old Auditor role means the same
// evaluator call that says "run the tests" later says "tests ran", and that
// self-certification is only safe while the item vocabulary stays user-authored
// and finite. `applyTransitions` is where that bound is enforced (spec §2.1):
// the prompt restates it, but the prompt is the component being constrained.

import { z } from "zod";

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

export interface TransitionResult {
  backlog: InstructionItem[];
  applied: { item: InstructionItem; from: ItemStatus; at: number }[];
  rejected: { transition: ItemTransition; reason: string }[];
  // True only when an item REACHED `done`. This is the sole input to
  // guard.recordProgress(), which zeroes the consecutive-auto-reply cap, so a
  // finite backlog has to yield finite progress — which is what makes the
  // terminal states below a one-way door rather than a preference.
  progressed: boolean;
}

const TERMINAL: ReadonlySet<ItemStatus> = new Set<ItemStatus>(["done", "skipped", "failed"]);

// `dependsOn` is the one field an item shares by reference, so a shallow spread
// would hand the caller's array back out of a function documented as pure.
function cloneItem(i: InstructionItem): InstructionItem {
  return i.dependsOn ? { ...i, dependsOn: [...i.dependsOn] } : { ...i };
}

export function applyTransitions(
  backlog: InstructionItem[],
  transitions: ItemTransition[],
  now: number,
): TransitionResult {
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
      rejected.push({ transition: { ...raw }, reason: "malformed transition" });
      continue;
    }
    const t = parsed.data;

    const item = byId.get(t.id);
    // No branch here may create an item: an evaluator that can mint an id can
    // mint progress. Rejections are returned rather than dropped so the engine
    // can log the attempt.
    if (!item) {
      rejected.push({ transition: t, reason: "unknown item id" });
      continue;
    }
    // §2.2's terminal states are one-way. An evaluator able to walk an item back
    // out of `done` could re-complete it once per pass forever, resetting the
    // runaway guard every round — §2.1's mint-progress attack reached without
    // minting an id. Revival off `blocked` (non-terminal) stays open; reviving a
    // skipped item is a user tap in the backlog drawer (§4.3) — the wrap-up
    // summary is a push notification with no tap target — not an evaluator move.
    if (TERMINAL.has(item.status)) {
      rejected.push({ transition: t, reason: `${item.status} is terminal` });
      continue;
    }
    if (TERMINAL.has(t.status) && (t.evidence ?? "").trim() === "") {
      rejected.push({ transition: t, reason: `${t.status} requires evidence` });
      continue;
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

// Every field rendered here is extraction output, ids included, so any of them can
// carry a newline that would forge an extra list line — and a forged line hands the
// evaluator an id the user-authored vocabulary §2.1 rests on never contained.
function oneLine(s: string): string {
  return s.replace(/\s+/g, " ").trim();
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
