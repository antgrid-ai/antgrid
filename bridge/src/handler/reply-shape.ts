// bridge/src/handler/reply-shape.ts
import type { CapCommand } from "../structured/chat-session";
import { oneLine } from "./backlog";
import type { HandlerDecision } from "./decision";

// Harness guards on the gate-bypassing inject channel (alongside the destructive
// floor, which the engine applies separately): a compromised or hallucinating
// judge must not inject an unbounded blob, nor smuggle several commands into one
// "handle" via embedded newlines or control chars.
export const MAX_REPLY_CHARS = 4096;
const VERB = /^\/[^\s/\\]+$/;
const CONTROL_CHARS = /[\x00-\x1f\x7f]/;

// Re-exported because the engine flattens the same way for its push bodies, where
// a stray newline renders as a broken multi-line notification. It is DEFINED in
// backlog.ts, which is import-free: the prompt renderers there and this module
// enforce one flattening rule, and a second copy is a second place to keep it.
export { oneLine };

/** Split a slash_command value on its FIRST run of whitespace. The tail keeps its
 *  internal spacing: it is typed at the agent verbatim, and a control character
 *  hiding in it must still reach the guard below rather than be normalized away. */
export function splitSlashCommand(value: string): { verb: string; args: string } {
  const v = value.trim();
  const i = v.search(/\s/);
  return i < 0 ? { verb: v, args: "" } : { verb: v.slice(0, i), args: v.slice(i).trimStart() };
}

/** Matched on `name`, never on `id`: an id is per-backend routing metadata whose
 *  prefix differs by agent (`cmd:`, `skill:`, `builtin:`) — codex emits no `cmd:`
 *  ids at all — while `name` is the bare verb on every one of them. Case-
 *  insensitive because names come verbatim from filesystem paths and frontmatter. */
export function findCommand(catalog: CapCommand[] | undefined, verb: string): CapCommand | undefined {
  if (!verb) return undefined;
  const name = verb.replace(/^\//, "").toLowerCase();
  return catalog?.find((c) => c.name.toLowerCase() === name);
}

export interface ReplyShape {
  /** The free-text reply, flattened to the one line injectReply will submit. */
  reply: string;
  /** The whole trimmed slash_command value, verb and args together. */
  actionText: string;
  verb: string;
  args: string;
  /** What is injected, recorded in the activity feed and hashed by the runaway
   *  guard: the full command line, never one half of the split. */
  written: string;
}

export interface ShapeRejection {
  reason: string;
  /** Whether re-asking the judge could fix it. False for catalog membership: the
   *  catalog is already in the prompt, so a second miss names a command that does
   *  not exist rather than a formatting slip. */
  retryable: boolean;
}

export function replyShape(decision: HandlerDecision): ReplyShape {
  // Flattened here, before anything reads it: injectReply submits with a trailing
  // CR, so a line break INSIDE the reply submits early and turns one decision into
  // several commands. Judges write ordinary paragraphs, so collapse to the single
  // line that will actually be typed rather than refusing the reply. Only
  // whitespace collapses — Ctrl-C, EOF and escape have no formatting reading and
  // still fail the control-char rule below.
  const reply = oneLine(decision.reply ?? "");
  const actionText = (decision.action?.kind === "slash_command" ? decision.action.value : "").trim();
  const { verb, args } = actionText ? splitSlashCommand(actionText) : { verb: "", args: "" };
  return { reply, actionText, verb, args, written: actionText || reply };
}

/** The one place a "handle" is refused for its SHAPE. Safety verdicts (the
 *  destructive floor, the runaway guard) live in the engine and deliberately not
 *  here: this function is also the judge's retry trigger, and a retry around a
 *  safety verdict is a bypass. */
export function checkReplyShape(shape: ReplyShape, catalog: CapCommand[] | undefined): ShapeRejection | null {
  if (!shape.reply && !shape.actionText) return { reason: "empty reply", retryable: false };
  // Setting both is a judge error, not a preference to resolve here. Picking one
  // sends the other nowhere — unvalidated, unguarded and unread — and injecting
  // both would be exactly the two-commands-from-one-decision the control-char rule
  // exists to stop. The prompt states the rule, which is what makes this teachable.
  if (shape.reply && shape.actionText) {
    return { reason: "set either reply or action, not both", retryable: true };
  }
  if (shape.written.length > MAX_REPLY_CHARS) {
    return { reason: `reply too long (${shape.written.length} > ${MAX_REPLY_CHARS})`, retryable: true };
  }
  if (CONTROL_CHARS.test(shape.written)) {
    return { reason: "reply contains control characters", retryable: true };
  }
  if (!shape.actionText) return null;
  // The VERB alone carries the shape rule; the argument tail is free text the
  // destructive floor inspects instead.
  if (!VERB.test(shape.verb)) {
    return { reason: "slash command value is not a simple verb", retryable: true };
  }
  // Membership is conditional on a catalog being NON-EMPTY, matching the branch
  // buildDecidePrompt renders on (`opts.commands?.length`): an empty array is told
  // "no catalog available, prefer plain instructions" and must not then be refused
  // every verb it emits — the silent-refusal loop this design exists to end,
  // inverted. Absent or empty means "none available" (a PTY, a driver reporting
  // none, discovery that has not landed) — not "this agent has no commands" — and
  // refusing on that would ground every terminal session. There, an invented
  // command reaches the agent, is rejected, and shows up in the next context:
  // visible and recoverable.
  if (catalog?.length && !findCommand(catalog, shape.verb)) {
    return { reason: `slash command ${shape.verb} is not in this session's command catalog`, retryable: false };
  }
  return null;
}
