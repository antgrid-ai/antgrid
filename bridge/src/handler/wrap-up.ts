// bridge/src/handler/wrap-up.ts
//
// The morning-after summary, composed once.
//
// The notification and the durable record are two renderings of ONE selection —
// which items each outcome group names, the +N cap, the group order. Splitting
// that decision between the push and the stored copy is how the two come to
// describe the same session differently, on a surface whose whole job is to be
// read hours later.
//
// The rule the shape below enforces: freeze what dies with the session, never
// freeze what outlives it. A `guard_blocked` report dies with it — `disarm` drops
// the session and takes `s.escalations` with it, and nothing can re-derive them —
// so its count and reasons are FIELDS. The open-undo count outlives it: an undo
// taken after the wrap-up spends the entry, and a re-arm on the slot retires the
// offers outright, so a frozen count becomes a lie in two independent ways. It is
// an argument to the push renderer — a point-in-time artifact by nature — and
// reaches neither the record nor the activity row, which is append-only and would
// freeze it by construction.

import {
  clip, oneLine, previewForUser, summarize,
  type InstructionItem,
} from "./backlog";

export type SummaryStatus = keyof ReturnType<typeof summarize>;

// The non-`done` outcomes are what the summary is for — an item nobody could
// reach is the one thing the user has to act on — so `done` leads and the rest
// follow in descending order of how much they demand.
const SUMMARY_GROUPS: [SummaryStatus, string][] = [
  ["done", "Done"],
  ["failed", "Failed"],
  ["blocked", "Blocked"],
  ["skipped", "Skipped"],
];

// The record keeps a larger sample than the push shows: an OS notification limit
// is not a reason to cripple a card that has a screen to itself.
export const MAX_WRAPUP_ITEMS_PER_GROUP = 8;
export const MAX_PUSH_ITEMS_PER_GROUP = 3;
// Explicit, where previewForUser's own default is 300: every stored record is
// replayed in full on `handler:status`, which is a REPLAY_TYPE emitted twice per
// handler event and encrypted across the relay to a phone. The frame budget this
// number buys is stated on HandlerWrapUpWire (../protocol.ts).
export const MAX_WRAPUP_TEXT_CHARS = 120;
// One activity row's detail, on the same terms as every other sampled row.
export const MAX_WRAPUP_DETAIL_CHARS = 200;
export const MAX_BLOCKED_REASONS = 3;
// Tighter than the record's three: the push is read on a lock screen, where the
// OS truncates the tail, and the card behind it carries the full set.
export const MAX_PUSH_BLOCKED_REASONS = 2;
export const PUSH_BLOCKED_REASON_CHARS = 80;

export interface WrapUpOutcome {
  status: SummaryStatus;
  // The TRUE count, which is what `+N more` is derived against. `more` is never
  // stored: two numbers that must agree are two numbers that can disagree.
  total: number;
  items: string[];
}

export interface WrapUpRecord {
  wrapUpId: string;
  terminalId: string;
  at: number;
  goal: string;
  outcomes: WrapUpOutcome[];
  blockedTotal: number;
  blockedReasons: string[];
}

function groupLabel(status: SummaryStatus): string {
  return SUMMARY_GROUPS.find(([s]) => s === status)?.[1] ?? status;
}

/** The one place item text is escaped and clipped on its way into a record. */
function preview(text: string): string {
  return previewForUser(oneLine(text), MAX_WRAPUP_TEXT_CHARS);
}

/**
 * Everything the summary says about a finished session, decided once.
 *
 * `blockedReports` is the guard_blocked subset of the session's escalations —
 * the count is the array's length, so a caller cannot pass a total that its
 * reasons contradict.
 */
export function buildWrapUp(args: {
  wrapUpId: string;
  terminalId: string;
  at: number;
  goal: string;
  backlog: InstructionItem[];
  blockedReports: readonly { reasoning: string }[];
}): WrapUpRecord {
  const counts = summarize(args.backlog);
  const outcomes: WrapUpOutcome[] = [];
  for (const [status] of SUMMARY_GROUPS) {
    const total = counts[status];
    if (total === 0) continue;
    outcomes.push({
      status,
      total,
      items: args.backlog
        .filter((i) => i.status === status)
        .slice(0, MAX_WRAPUP_ITEMS_PER_GROUP)
        .map((i) => preview(i.text)),
    });
  }
  return {
    wrapUpId: args.wrapUpId,
    terminalId: args.terminalId,
    at: args.at,
    goal: preview(args.goal),
    outcomes,
    blockedTotal: args.blockedReports.length,
    blockedReasons: args.blockedReports.slice(0, MAX_BLOCKED_REASONS).map((e) => preview(e.reasoning)),
  };
}

/** `Done: item a, item b +2 more` — a bare count reads the same whether the work
 *  was moot or the assistant gave up, so every group names its items. */
export function wrapUpGroupLine(o: WrapUpOutcome, cap: number): string {
  const shown = o.items.slice(0, cap);
  const more = o.total - shown.length;
  return `${groupLabel(o.status)}: ${shown.join(", ")}${more > 0 ? ` +${more} more` : ""}`;
}

/**
 * Names what a guard refused rather than counting it: a bare count reads the same
 * whether the guard stopped something trivial or the one thing the session existed
 * to do. The push is the only channel that reaches a phone whose app was not
 * running when the `handler:activity` rows went out — `handler:status` replays
 * sessions, snapshots and wrap-ups, never the feed — so it has to say it here.
 */
function blockedClause(rec: WrapUpRecord, cap: number, chars: number): string {
  const shown = rec.blockedReasons.slice(0, cap).map((r) => clip(r, chars));
  if (shown.length === 0) return `${rec.blockedTotal} action(s) Handler could not take`;
  const more = rec.blockedTotal - shown.length;
  return `Could not: ${shown.join("; ")}${more > 0 ? ` +${more} more` : ""}`;
}

function clauses(rec: WrapUpRecord, cap: number): string[] {
  return rec.outcomes.map((o) => wrapUpGroupLine(o, cap));
}

/**
 * The wrap-up notification. Last thing the user reads about this session, and
 * the session is disarmed by the time they read it — so it is also the last
 * place the undo can be made discoverable before it is needed, which is
 * why `openUndos` is passed in live rather than read off the record.
 */
export function wrapUpPushBody(rec: WrapUpRecord, { openUndos }: { openUndos: number }): string {
  const parts = clauses(rec, MAX_PUSH_ITEMS_PER_GROUP);
  // Ahead of the blocked clause: the OS truncates the tail, and of the two only
  // this one expires — the reports keep on the wrap-up card, while the offer to
  // undo is gone once the user stops looking for it.
  if (openUndos > 0) parts.push(`${openUndos} flagged action(s) can still be undone`);
  if (rec.blockedTotal > 0) {
    parts.push(blockedClause(rec, MAX_PUSH_BLOCKED_REASONS, PUSH_BLOCKED_REASON_CHARS));
  }
  return [`Handler: done — ${rec.goal || "session complete"}`, ...parts].join(". ");
}

/**
 * The `wrapped_up` activity row's detail. No goal — the row's session identity
 * is already the terminal it names, and the goal rides the record. No undo
 * clause at any count: the feed's jsonl is append-only, so anything written here
 * is frozen for good.
 */
export function wrapUpDetail(rec: WrapUpRecord): string {
  const parts = clauses(rec, MAX_PUSH_ITEMS_PER_GROUP);
  if (rec.blockedTotal > 0) parts.push(blockedClause(rec, MAX_BLOCKED_REASONS, MAX_WRAPUP_TEXT_CHARS));
  return clip(parts.join(". "), MAX_WRAPUP_DETAIL_CHARS);
}
