import type { AbMessage } from "../protocol";

const AGENT_LABELS: Record<string, string> = {
  permission_request: "Permission needed",
  task_complete: "Task complete",
  idle: "Waiting for you",
  error: "Agent error",
};

export function composePush(msg: AbMessage): { title: string; body: string; kind: "agent" | "handler" } | null {
  if (msg.type === "notification:push") {
    const label = AGENT_LABELS[msg.notificationType] ?? "Agent";
    // body deliberately does NOT fall back to sessionTitle: that would make
    // title === body, which is the whole point of carrying two fields.
    const title = msg.sessionTitle && msg.sessionTitle.length > 0 ? msg.sessionTitle : label;
    const body = msg.message && msg.message.length > 0 ? msg.message : label;
    return { title, body, kind: "agent" };
  }
  if (msg.type === "handler:escalation") {
    const title = msg.urgency === "high" ? "Handler — urgent" : "Handler needs you";
    const body = msg.question && msg.question.length > 0 ? msg.question : "Agent needs you";
    return { title, body, kind: "handler" };
  }
  return null;
}
