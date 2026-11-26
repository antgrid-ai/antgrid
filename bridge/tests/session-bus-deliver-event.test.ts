// bridge/tests/session-bus-deliver-event.test.ts
import { test, expect } from "bun:test";
import { lineForEvent } from "../src/session-bus/deliver-event";
import { stampEnvelope } from "../src/session-bus/envelope";
import { emptyDeliveries, enqueueLine } from "../src/session-bus/delivery-queue";
import type { SessionBusEvent } from "../src/session-bus/coordinator";
import type { SessionMemberKey, SessionMemberRef } from "../src/protocol";

const SESSION = "s1";
const FROM: SessionMemberKey = { machineId: "m2", projectId: "p2", sessionId: "s2" };
const PEER: SessionMemberRef = { ...FROM, machineLabel: "linux box", projectLabel: "ingest", sessionName: "Trace the 500s" };
const T0 = 5_000_000;

function event(over: Partial<SessionBusEvent> & { messageId?: string; summary?: string } = {}): SessionBusEvent {
  const threadId = over.threadId === undefined ? "th-1" : over.threadId;
  const summary = over.summary ?? "the migration is already reverted";
  return {
    kind: over.kind ?? "notify",
    sessionId: over.sessionId ?? SESSION,
    threadId,
    opensThread: over.opensThread ?? true,
    peer: over.peer ?? PEER,
    ...(over.answering === undefined ? {} : { answering: over.answering }),
    envelope: over.envelope ?? stampEnvelope(
      { threadId, contextId: "ctx-1", parts: [{ kind: "text", text: "it ran at 12:02" }], summary },
      { messageId: over.messageId ?? "msg-1", peer: PEER, now: T0 },
    ),
  };
}

// A post is read when the target chooses (§7.1). This is the one null the module
// is allowed to return, and it has to be asserted rather than assumed: every
// other null here is an arrival that folded, acked and delivered no character,
// which no log on either machine distinguishes from a quiet success.
test("a post owes the local agent no line", () => {
  expect(lineForEvent(event({ kind: "post" }))).toBeNull();
});

test("a notify becomes exactly one line, keyed by the message id", () => {
  const line = lineForEvent(event({ messageId: "msg-7" }));
  expect(line).not.toBeNull();
  expect(line!.id).toBe("msg-7");
  expect(line!.sessionId).toBe(SESSION);
  expect(line!.text).toContain("it ran at 12:02");
});

// The verb says whether to interrupt; the thread STORE says which template. An
// id alone cannot: every send mints one (§4.3), so a first contact and a
// continuation both carry one and only `opensThread` tells them apart.
test("a first contact on a thread renders the notify template and names the thread", () => {
  const line = lineForEvent(event({ threadId: "th-9", opensThread: true }))!;
  expect(line.kind).toBe("notify");
  expect(line.text).toContain("delivery: notify (template v3)");
  expect(line.text).toContain("has sent this session a message.");
  expect(line.text).toContain('use antgrid_reply on thread "th-9".');
});

test("a notify on a thread this receiver already holds renders the reply template", () => {
  const line = lineForEvent(event({ threadId: "th-9", opensThread: false }))!;
  expect(line.kind).toBe("reply");
  expect(line.text).toContain("delivery: reply (template v3)");
  expect(line.text).toContain("has answered on a thread this session already");
});

// What this session last said on the thread is the only thing that lets the
// reader place an answer that arrived hours later. The coordinator reads it off
// the log at fold time; nothing here goes looking, so an event that carries none
// must render a header that simply does not claim one.
test("a reply names what it answers, and omits the clause when the event carries none", () => {
  const placed = lineForEvent(event({
    threadId: "th-9",
    opensThread: false,
    answering: "did the down-migration run",
  }))!;
  expect(placed.text).toContain('It answers: "did the down-migration run".');

  const unplaceable = lineForEvent(event({ threadId: "th-9", opensThread: false, messageId: "msg-2" }))!;
  expect(unplaceable.text).not.toContain("It answers:");
});

// The coordinator re-emits a redelivered frame, and the id is what makes that
// cost nothing rather than hand the agent the same message twice.
test("two emissions of one message are a single line at the queue", () => {
  const line = lineForEvent(event({ messageId: "msg-3" }))!;
  const once = enqueueLine(emptyDeliveries(), { ...line, queuedAt: T0 });
  const twice = enqueueLine(once, { ...line, queuedAt: T0 + 1 });
  expect(twice.lines).toHaveLength(1);
  expect(twice).toBe(once);
});
