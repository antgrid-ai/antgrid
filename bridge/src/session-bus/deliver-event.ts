// Which inbound bus events become a line in the receiving agent's session, and
// what that line says.
//
// One place, and a pure one, because the mapping is where the two halves of the
// protocol meet: the coordinator decides what ARRIVED, the templates decide how
// a delivery READS, and this decides which arrivals an agent is told about at
// all. An event with no line here is not lost — it is on the task record, where
// `antgrid_get_task` reads it — it simply does not interrupt.
//
// Nothing here injects or persists: it returns a line for the queue, which is
// what makes the "wake for a completed task survives a restart" guarantee a
// property of one module rather than of this mapping.

import type { SessionMemberOf, BusEnvelope, BusPart } from "../protocol";
import { briefScope } from "./brief-store";
import type { SessionBusEvent } from "./coordinator";
import type { QueuedLine } from "./delivery-queue";
import { renderAnswer, renderCancel, renderTask, renderWake, type TaskArtifactHandle } from "./delivery";
import { takeAskedQuestion } from "./api";

export interface EventDeliveryDeps {
  abDir: string;
  projectId: string;
  /** The lead this session was created under, from its own membership row. A
   *  peer with no row cannot be delivered to: every peer-facing template names
   *  the lead, and inventing one would put a fabricated sender on an
   *  instruction. */
  memberOf: (sessionId: string) => SessionMemberOf | undefined;
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
 * The four that do are the four that change what the agent should be doing: work
 * arriving, work it handed out finishing, an answer it was blocked on, and work
 * it was told to stop. Everything else — a finding, an expiry, an ack — is
 * recorded and readable, and interrupting a turn for it would spend the agent's
 * attention on something no decision waits on.
 */
export function lineForEvent(
  event: SessionBusEvent,
  deps: EventDeliveryDeps,
): Omit<QueuedLine, "queuedAt"> | null {
  const envelope = envelopeOf(event);

  if (event.kind === "assigned") {
    const lead = deps.memberOf(event.sessionId);
    if (!lead || !envelope) return null;
    return {
      id: envelope.messageId,
      sessionId: event.sessionId,
      kind: "task",
      text: renderTask({
        lead,
        taskId: event.task.taskId,
        summary: envelope.metadata.summary,
        instruction: textOf(envelope.parts),
        scope: briefScope(deps.abDir, deps.projectId, event.sessionId),
        artifacts: artifactsOf(envelope.parts),
      }),
    };
  }

  if (event.kind === "transitioned" && envelope) {
    // The task's own role, not the session's: a session that leads one exchange
    // and works another gets a wake for the first and an answer for the second.
    if (event.task.role === "lead") {
      if (event.state !== "completed" && event.state !== "failed" && event.state !== "input-required") {
        // `working` from a peer is progress, not news — the lead asked for it to
        // start. Waking a lead for it costs a turn and tells it nothing it did
        // not already assume.
        return null;
      }
      return {
        id: envelope.messageId,
        sessionId: event.sessionId,
        kind: "wake",
        text: renderWake({
          peer: event.task.peer,
          taskId: event.task.taskId,
          state: event.state,
          ...(event.task.waitingOn === undefined ? {} : { waitingOn: event.task.waitingOn }),
          summary: envelope.metadata.summary,
        }),
      };
    }

    // A peer's task moving back to `working` is how a lead's answer travels:
    // there is no answer verb on the wire, and `input-required -> working` is
    // the transition only an answer can cause (spec 5.3).
    if (event.state !== "working") return null;
    const lead = deps.memberOf(event.sessionId);
    if (!lead) return null;
    const question = takeAskedQuestion(
      deps.abDir,
      deps.projectId,
      event.sessionId,
      event.task.taskId,
      deps.now(),
    );
    return {
      id: envelope.messageId,
      sessionId: event.sessionId,
      kind: "answer",
      text: renderAnswer({
        lead,
        taskId: event.task.taskId,
        // The stored ask is gone after a restart or a lapsed row, and the answer
        // still has to read on its own — so say the question is missing rather
        // than render an answer to nothing.
        question: question ?? "(the question this session asked is no longer on record)",
        answer: textOf(envelope.parts),
        scope: briefScope(deps.abDir, deps.projectId, event.sessionId),
      }),
    };
  }

  if (event.kind === "canceled") {
    const lead = deps.memberOf(event.sessionId);
    // Only the side WORKING the task is told to stop; the lead is the one that
    // asked for the cancel and has already been answered by its own tool call.
    if (!lead || event.task.role !== "peer") return null;
    return {
      // A task reaches `canceled` once and never leaves it, so the task id alone
      // is a stable key for the one line a cancel can ever produce.
      id: `${event.task.taskId}:canceled`,
      sessionId: event.sessionId,
      kind: "cancel",
      text: renderCancel({ lead, taskId: event.task.taskId, reason: event.reason }),
    };
  }

  return null;
}
