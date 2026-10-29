import type { AbMessage } from "../protocol";

// HAND-MIRRORED in `agentNotificationKinds`
// (app/lib/utils/notification_routing.dart); keep both sides in sync. Symbols
// are Unicode 7.0 or older, so every supported OS has a glyph for them. U+FE0F
// asks for the colour form; without it ⏸ and ⚠ render as monochrome text.
const AGENT_KINDS: Record<string, { label: string; symbol: string }> = {
  permission_request: { label: "Permission needed", symbol: "🔐" },
  awaiting_input: { label: "Needs your input", symbol: "❓" },
  question: { label: "Agent asks", symbol: "❓" },
  task_complete: { label: "Task complete", symbol: "✅" },
  idle: { label: "Waiting for you", symbol: "⏸️" },
  error: { label: "Agent error", symbol: "⚠️" },
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
    const kind = AGENT_KINDS[msg.notificationType];
    const label = kind?.label ?? "Agent";
    // Trimmed like `notificationHeadline` (app): a blank name must not blank the banner.
    const title = msg.sessionTitle?.trim() || label;
    // body never falls back to sessionTitle, or title === body.
    const text = msg.message || label;
    const body = kind ? `${kind.symbol} ${text}` : text;
    return { title, body, kind: "agent", sourceMessageId: msg.id, ...(msg.sessionId ? { terminalId: msg.sessionId } : {}) };
  }
  if (msg.type === "handler:escalation") {
    // HAND-MIRRORED in `handlerEscalationTitle` (app/lib/widgets/agent_notification_surfacer.dart).
    // A nonBlocking ask is still pushed, but never titled as a stop: the work went on.
    const title = msg.urgency === "high"
      ? "Handler — urgent"
      : msg.nonBlocking === true ? "Handler has a question" : "Handler needs you";
    const body = msg.question && msg.question.length > 0 ? msg.question : "Agent needs you";
    return { title, body, kind: "handler", sourceMessageId: msg.escalationId, terminalId: msg.terminalId };
  }
  return null;
}
