import type { AbMessage } from "../protocol";

const AGENT_LABELS: Record<string, string> = {
  permission_request: "Permission needed",
  awaiting_input: "Needs your input",
  task_complete: "Task complete",
  idle: "Waiting for you",
  error: "Agent error",
};

/** The routing ids ride along with the strings because this is the only
 *  per-message-type switch with Zod-narrowed access to them: a second switch in
 *  the dispatcher would have to re-narrow the union to reach `escalationId` and
 *  `sessionId`. `terminalId` is omitted rather than emitted empty — the phone
 *  treats a present key as a session it can resolve. */
export interface ComposedPush {
  title: string;
  body: string;
  kind: "agent" | "handler";
  sourceMessageId: string;
  terminalId?: string;
}

export function composePush(msg: AbMessage): ComposedPush | null {
  if (msg.type === "notification:push") {
    const label = AGENT_LABELS[msg.notificationType] ?? "Agent";
    // body deliberately does NOT fall back to sessionTitle: that would make
    // title === body, which is the whole point of carrying two fields.
    const title = msg.sessionTitle && msg.sessionTitle.length > 0 ? msg.sessionTitle : label;
    const body = msg.message && msg.message.length > 0 ? msg.message : label;
    return { title, body, kind: "agent", sourceMessageId: msg.id, ...(msg.sessionId ? { terminalId: msg.sessionId } : {}) };
  }
  if (msg.type === "handler:escalation") {
    // HAND-MIRRORED in `handlerEscalationTitle`
    // (app/lib/screens/workspace_shell.dart), which titles the SAME escalation
    // when the app is attached while this titles the pushed copy. Nothing in CI
    // couples them, so a string changed on one side alone describes one event
    // two different ways depending only on whether the device was awake.
    //
    // A `nonBlocking` row is a question Handler raised on a pass that had
    // already replied to the agent: the work went on, so the word must not be
    // the one that means the session stopped. It never takes the urgent band —
    // raiseAsk mints `normal` for every one — so `high` still wins outright. It
    // is still pushed, though: a question nobody is shown is not a question.
    //
    // THE LIMIT, because this title is the whole of what an ask gets on a locked
    // phone: the sealed payload is title/body/kind/sourceMessageId/terminalId
    // and the dispatcher's own routing ids (see push-dispatcher.ts). There is no
    // interruption level, no channel and no priority anywhere in it, so "Handler
    // has a question" buzzes, lights the screen and sits on the lock screen
    // exactly as "Handler needs you" does. Everything else that separates a
    // question from a stop is visible only AFTER the user has been interrupted,
    // unlocked the phone and opened the Handler tab. A quieter delivery channel
    // means new payload fields plus per-platform channel plumbing on both
    // stores, and is its own change.
    const title = msg.urgency === "high"
      ? "Handler — urgent"
      : msg.nonBlocking === true ? "Handler has a question" : "Handler needs you";
    const body = msg.question && msg.question.length > 0 ? msg.question : "Agent needs you";
    return { title, body, kind: "handler", sourceMessageId: msg.escalationId, terminalId: msg.terminalId };
  }
  return null;
}
