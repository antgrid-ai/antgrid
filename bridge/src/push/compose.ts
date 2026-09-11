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
    const title = msg.urgency === "high" ? "Handler — urgent" : "Handler needs you";
    const body = msg.question && msg.question.length > 0 ? msg.question : "Agent needs you";
    return { title, body, kind: "handler", sourceMessageId: msg.escalationId, terminalId: msg.terminalId };
  }
  return null;
}
