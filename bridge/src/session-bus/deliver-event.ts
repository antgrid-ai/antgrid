// Which arrivals become a line in the receiving agent's session, and what that
// line says.
//
// One place, and a pure one, because the mapping is where the two halves of the
// protocol meet: the coordinator decides what ARRIVED, the templates decide how
// a delivery READS, and this decides which arrivals an agent is told about at
// all. An arrival with no line here is not lost — the message log still holds
// it — it simply does not interrupt.
//
// Nothing here injects or persists: it returns a line for the queue, which is
// what makes the "a line survives a restart" guarantee a property of one module
// rather than of this mapping.

import type { BusEnvelope, BusPart } from "../protocol";
import type { SessionBusEvent } from "./coordinator";
import type { QueuedLine } from "./delivery-queue";
import type { TaskArtifactHandle } from "./delivery";

export interface EventDeliveryDeps {
  abDir: string;
  projectId: string;
  now: () => number;
}

function textOf(parts: readonly BusPart[]): string {
  return parts
    .filter((p): p is Extract<BusPart, { kind: "text" }> => p.kind === "text")
    .map((p) => p.text)
    .join("\n\n");
}

function artifactsOf(parts: readonly BusPart[]): TaskArtifactHandle[] {
  return parts
    .filter((p): p is Extract<BusPart, { kind: "artifact" }> => p.kind === "artifact")
    .map((p) => ({ artifactId: p.artifactId, name: p.name, summary: p.summary }));
}

function envelopeOf(event: SessionBusEvent): BusEnvelope | null {
  return "envelope" in event ? event.envelope : null;
}

/**
 * The line one inbound event owes the local agent, or null when it owes none.
 *
 * Today it owes none. Every arrival is a message, and a message is read when the
 * target chooses (`docs/session-messaging.md` §7.1); rendering one into a line
 * here would interrupt a turn on the sender's say-so, with none of §7.4's budget
 * in front of it. The mapping stays a function, and the part reductions above
 * stay with it, so the notify verb has one place to arrive at and rendering
 * stays outside the coordinator's fold.
 */
export function lineForEvent(
  event: SessionBusEvent,
  deps: EventDeliveryDeps,
): Omit<QueuedLine, "queuedAt"> | null {
  return null;
}
