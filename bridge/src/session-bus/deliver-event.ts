// Which arrivals become a line in the receiving agent's session, and what that
// line says.
//
// One place, and a pure one, because the mapping is where the two halves of the
// protocol meet: the coordinator decides what ARRIVED, the templates decide how
// a delivery READS, and this decides which arrivals an agent is told about at
// all. An arrival with no line here is not lost — the message log still holds
// it — it simply does not interrupt.
//
// Two arrivals, not one. A bus event comes off the wire from the other machine;
// a JOIN is written by this machine's own app, because no bridge can reach
// another (D7) and so nothing arrives from the peer to announce itself. Both
// produce the same kind of line and both go through the same queue.
//
// Nothing here injects or persists: it returns a line for the queue, which is
// what makes the "a line survives a restart" guarantee a property of one module
// rather than of this mapping.

import type { SessionMemberRef, BusEnvelope, BusPart } from "../protocol";
import { sha256Hex } from "./artifact-store";
import type { SessionBusEvent } from "./coordinator";
import type { QueuedLine } from "./delivery-queue";
import { renderJoined, type TaskArtifactHandle } from "./delivery";

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

export interface JoinInput {
  /** The LOCAL lead session that gained the member. */
  sessionId: string;
  /** That lead session's own name, for the delivery's `To:` line. */
  leadSessionName?: string;
  /** The member as the app recorded it, Capability Card included. */
  member: SessionMemberRef;
  /** The brief the human wrote for that machine, when the carrier sent one. */
  brief?: string;
}

/**
 * The queue id one join can ever produce, so a carrier that retries its
 * `session:member-record` does not queue the notice twice.
 *
 * Hashed rather than joined: the three address parts are 200 characters each on
 * the wire and a queued id is bounded well below their sum, so a concatenation
 * would be truncated — and a truncated address collides two machines onto one
 * id, which silently drops the second machine's notice.
 */
export function joinLineId(member: SessionMemberRef): string {
  const address = JSON.stringify([member.machineId, member.projectId, member.sessionId]);
  return `joined:${sha256Hex(new TextEncoder().encode(address))}`;
}

/**
 * The line a lead session owes its agent when a machine joins it (spec 3.3).
 *
 * Always a line, unlike an event: a join is the human handing the lead a
 * machine, and a lead that learns of a peer only by calling `antgrid_list_peers`
 * would never learn of it at all.
 */
export function lineForJoin(input: JoinInput): Omit<QueuedLine, "queuedAt"> {
  return {
    id: joinLineId(input.member),
    sessionId: input.sessionId,
    kind: "joined",
    text: renderJoined({
      peer: input.member,
      ...(input.leadSessionName === undefined ? {} : { leadSessionName: input.leadSessionName }),
      ...(input.brief === undefined ? {} : { brief: input.brief }),
    }),
  };
}
