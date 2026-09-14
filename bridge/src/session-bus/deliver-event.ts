// Which arrivals become a line in the receiving agent's session, and what that
// line says.
//
// One place, and a pure one, because the mapping is where the two halves of the
// protocol meet: the coordinator decides what ARRIVED, the templates decide how
// a delivery READS, and this decides which arrivals an agent is told about at
// all. An arrival with no line here is not lost — the message log still holds
// it — it simply does not interrupt.
//
// Nothing here reads, injects or persists: it returns a line for the queue from
// the event alone, which is what makes the "a line survives a restart" guarantee
// a property of one module rather than of this mapping.

import type { BusPart } from "../protocol";
import type { SessionBusEvent } from "./coordinator";
import type { QueuedLine } from "./delivery-queue";
import { renderNotify, renderReply, type BusArtifactHandle } from "./delivery";

function textOf(parts: readonly BusPart[]): string {
  return parts
    .filter((p): p is Extract<BusPart, { kind: "text" }> => p.kind === "text")
    .map((p) => p.text)
    .join("\n\n");
}

function artifactsOf(parts: readonly BusPart[]): BusArtifactHandle[] {
  return parts
    .filter((p): p is Extract<BusPart, { kind: "artifact" }> => p.kind === "artifact")
    .map((p) => ({ artifactId: p.artifactId, name: p.name, summary: p.summary }));
}

/**
 * The line one inbound event owes the local agent, or null when it owes none.
 *
 * A post owes none, and permanently: it is read when the target chooses (§7.1),
 * so rendering one here would interrupt a turn on the sender's say-so with none
 * of §7.4's budget in front of it. It is parked in the mailbox instead.
 *
 * A notify owes exactly one, keyed by the message id so a redelivered frame the
 * coordinator re-emits costs nothing at the queue. Which template it gets turns
 * on whether the thread already existed AT THIS RECEIVER and not on whether the
 * frame carries an id: every send mints one, so an id is always present, and
 * `opensThread` is the only thing that separates a first contact from a
 * continuation.
 */
export function lineForEvent(event: SessionBusEvent): Omit<QueuedLine, "queuedAt"> | null {
  if (event.kind === "post") return null;
  const { envelope } = event;
  const delivery = {
    peer: event.peer,
    threadId: event.threadId,
    summary: envelope.metadata.summary,
    text: textOf(envelope.parts) || undefined,
    unexpected: envelope.metadata.unexpected,
    artifacts: artifactsOf(envelope.parts),
  };
  const continues = event.threadId !== null && !event.opensThread;
  return {
    id: envelope.messageId,
    sessionId: event.sessionId,
    kind: continues ? "reply" : "notify",
    text: continues ? renderReply({ ...delivery, answering: event.answering }) : renderNotify(delivery),
  };
}
