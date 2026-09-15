import { test, expect } from "bun:test";
import { createMessage } from "../../src/protocol";
import { composePush } from "../../src/push/compose";
import { createPushDispatcher, type PushTarget } from "../../src/push/push-dispatcher";

const target: PushTarget = { pushToken: "tok", provider: "fcm", pushPubkey: "pk" };

function harness(overrides: Partial<Parameters<typeof createPushDispatcher>[0]> = {}) {
  const delivered: any[] = [];
  const sealed: string[] = [];
  const sealKeys: string[] = [];
  const d = createPushDispatcher({
    projectId: "p1",
    shouldFallback: () => true,
    resolveTargets: () => [target],
    machineUuid: () => "machine-uuid-1",
    seal: (json, pubkey) => { sealed.push(json); sealKeys.push(pubkey); return { epk: "E", box: "B" }; },
    deliver: (t, prov, blob) => delivered.push({ t, prov, blob }),
    ...overrides,
  });
  return { d, delivered, sealed, sealKeys };
}

test("composePush mirrors the app strings", () => {
  // The agent path's sourceMessageId is pinned to msg.id, not just to "a
  // string": the app dedups the live toast against the FCM one on that exact
  // equality (`_markNotified(msg.id)` vs `pushDedupKey`), so any other id here
  // surfaces one notification twice and leaves the push tap undeduped.
  const agent = createMessage("notification:push", { notificationType: "task_complete", message: "built", projectId: "p1" });
  expect(composePush(agent))
    .toEqual({ title: "Task complete", body: "built", kind: "agent", sourceMessageId: agent.id });
  expect(composePush(createMessage("handler:escalation", {
    projectId: "p1", escalationId: "e1", terminalId: "t", question: "Deploy?", reasoning: "", draftReply: "", urgency: "high", at: 1,
  }))).toEqual({ title: "Handler — urgent", body: "Deploy?", kind: "handler", sourceMessageId: "e1", terminalId: "t" });
});

// The three titles are hand-mirrored in `handlerEscalationTitle`
// (app/lib/screens/workspace_shell.dart) and pinned from the Dart side by
// app/test/screens/handler_escalation_title_test.dart, which reads these very
// literals back out of compose.ts. Changing a string here without changing it
// there gives the user two accounts of one event, depending only on whether the
// device was awake.
const escalation = (over: Record<string, unknown> = {}) => createMessage("handler:escalation", {
  projectId: "p1", escalationId: "e1", terminalId: "t", question: "Which schema?",
  reasoning: "", draftReply: "", urgency: "normal", at: 1, ...over,
});

test("composePush: an ask is titled as a question, not as a stop", () => {
  // Everything but the title is unchanged on purpose: `sourceMessageId` is what
  // dedups the pushed copy against the live one, so an ask must keep spending
  // the same id as any other escalation.
  expect(composePush(escalation({ nonBlocking: true })))
    .toEqual({ title: "Handler has a question", body: "Which schema?", kind: "handler", sourceMessageId: "e1", terminalId: "t" });
});

test("composePush: an escalation with no nonBlocking flag still stops the user", () => {
  // The absent case is what every row predating the ask feature looks like, and
  // every row an older bridge stripped the flag from and re-persisted.
  expect(composePush(escalation())!.title).toBe("Handler needs you");
  expect(composePush(escalation({ nonBlocking: false }))!.title).toBe("Handler needs you");
});

test("composePush: urgent outranks the ask wording", () => {
  // Unreachable through raiseAsk, which mints `normal` for every ask — asserted
  // so the precedence is a decision rather than an artifact of which branch
  // happened to be written first.
  expect(composePush(escalation({ urgency: "high", nonBlocking: true }))!.title).toBe("Handler — urgent");
});

test("composePush: sessionTitle becomes the title, message the body", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "task_complete", message: "Added a regression test", sessionTitle: "Fix auth bug", projectId: "p1",
  }))).toEqual({ title: "Fix auth bug", body: "Added a regression test", kind: "agent", sourceMessageId: expect.any(String) });
});

test("composePush: sessionTitle without a message keeps the label as the body", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "task_complete", sessionTitle: "Fix auth bug", projectId: "p1",
  }))).toEqual({ title: "Fix auth bug", body: "Task complete", kind: "agent", sourceMessageId: expect.any(String) });
});

test("composePush: neither field degrades to today's exact strings", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "task_complete", projectId: "p1",
  }))).toEqual({ title: "Task complete", body: "Task complete", kind: "agent", sourceMessageId: expect.any(String) });
});

test("composePush: body never falls back to sessionTitle", () => {
  const composed = composePush(createMessage("notification:push", {
    notificationType: "idle", sessionTitle: "Fix auth bug", projectId: "p1",
  }));
  expect(composed!.body).toBe("Waiting for you");
  expect(composed!.body).not.toBe("Fix auth bug");
});

test("composePush: empty strings are treated as absent", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "error", message: "", sessionTitle: "", projectId: "p1",
  }))).toEqual({ title: "Agent error", body: "Agent error", kind: "agent", sourceMessageId: expect.any(String) });
});

test("composePush: sessionTitle titles a permission request too", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "permission_request", message: "Run rm -rf build?", sessionTitle: "Fix auth bug", projectId: "p1",
  }))).toEqual({ title: "Fix auth bug", body: "Run rm -rf build?", kind: "agent", sourceMessageId: expect.any(String) });
});

test("suppressed peer → seals payload and delivers", () => {
  const { d, delivered, sealed } = harness();
  d.onOutbound(createMessage("handler:escalation", {
    projectId: "p1", escalationId: "e1", terminalId: "t", question: "Deploy?", reasoning: "", draftReply: "", urgency: "normal", at: 1,
  }));
  expect(delivered).toHaveLength(1);
  expect(delivered[0].t).toBe("tok");
  const payload = JSON.parse(sealed[0]);
  expect(payload).toEqual({
    title: "Handler needs you", body: "Deploy?", kind: "handler",
    projectId: "p1", machineUuid: "machine-uuid-1", terminalId: "t", sourceMessageId: "e1",
  });
});

test("a notification that names no session seals no terminalId key at all", () => {
  // An empty string would read to the phone as a session it should resolve and
  // fail to find; the hook path's sessionId is legitimately optional.
  const { d, sealed } = harness();
  d.onOutbound(createMessage("notification:push", { notificationType: "idle", projectId: "p1" }));
  expect(Object.keys(JSON.parse(sealed[0]))).not.toContain("terminalId");
});

test("a notification that names a session seals it as the terminalId", () => {
  // The hook path is the primary producer, and the phone resolves this id back
  // to a cached session uuid to pick the terminal to open — a neighbouring
  // field (msg.id, the checkoutId) type-checks here and lands on nothing.
  const { d, sealed } = harness();
  d.onOutbound(createMessage("notification:push", {
    notificationType: "task_complete", sessionId: "sess-1", projectId: "p1",
  }));
  expect(JSON.parse(sealed[0]).terminalId).toBe("sess-1");
});

test("an unbounded session title is capped before sealing", () => {
  // The relay rejects an oversized box outright and answers no push:result, so
  // an uncapped title loses the whole notification rather than truncating it.
  const { d, sealed } = harness();
  d.onOutbound(createMessage("notification:push", {
    notificationType: "task_complete", sessionTitle: "x".repeat(300), projectId: "p1",
  }));
  expect(JSON.parse(sealed[0]).title.length).toBe(120);
});

test("not suppressed (in-band available) → no delivery", () => {
  const { d, delivered } = harness({ shouldFallback: () => false });
  d.onOutbound(createMessage("notification:push", { notificationType: "idle", projectId: "p1" }));
  expect(delivered).toHaveLength(0);
});

test("no target → no delivery", () => {
  const { d, delivered } = harness({ resolveTargets: () => [] });
  d.onOutbound(createMessage("notification:push", { notificationType: "error", projectId: "p1" }));
  expect(delivered).toHaveLength(0);
});

test("multiple targets → one sealed delivery each, keyed to that phone's push key", () => {
  const second: PushTarget = { pushToken: "tok2", provider: "apns", pushPubkey: "pk2" };
  const { d, delivered, sealed, sealKeys } = harness({ resolveTargets: () => [target, second] });
  d.onOutbound(createMessage("notification:push", { notificationType: "task_complete", message: "built", projectId: "p1" }));
  expect(delivered.map((x) => x.t)).toEqual(["tok", "tok2"]);
  expect(delivered.map((x) => x.prov)).toEqual(["fcm", "apns"]);
  // Same plaintext, but sealed to each recipient's own key — never a shared ciphertext.
  expect(sealKeys).toEqual(["pk", "pk2"]);
  expect(JSON.parse(sealed[0])).toEqual(JSON.parse(sealed[1]));
});

test("non-user-facing message → ignored", () => {
  const { d, delivered } = harness();
  d.onOutbound(createMessage("terminal:input", { terminalId: "t", data: "x" }));
  expect(delivered).toHaveLength(0);
});
test("an armed slot's question is pushed once, by the escalation that can answer it", () => {
  // One hook invocation produces both: the agent's own question notification and
  // the forced escalation the Handler raises from the same event. They carry the
  // same sentence, so forwarding both buzzes the phone twice within milliseconds
  // — and the escalation is the half that must survive, since it is the one
  // carrying the escalationId the tap routes to.
  const { d, delivered } = harness({ isHandlerArmed: () => true });
  d.onOutbound(createMessage("notification:push", {
    notificationType: "question", message: "Which env?", sessionId: "t1", projectId: "p1",
  }));
  expect(delivered).toHaveLength(0);
  d.onOutbound(escalation({ terminalId: "t1", question: "Agent asks: Which env?", urgency: "high" }));
  expect(delivered).toHaveLength(1);
});

test("an unarmed slot keeps its question notification", () => {
  // Nothing else on that session ever says WHAT was asked: with no armed
  // Handler there is no escalation, and the CLI's own permission notification
  // reaches the phone as the same "Permission needed" every tool call gets.
  const { d, delivered } = harness();
  d.onOutbound(createMessage("notification:push", {
    notificationType: "question", message: "Which env?", sessionId: "t1", projectId: "p1",
  }));
  expect(delivered).toHaveLength(1);
});

test("arming one slot never silences another, nor any other notification kind", () => {
  const armed: string[] = [];
  const { d, delivered } = harness({ isHandlerArmed: (id) => { armed.push(id); return id === "t1"; } });
  d.onOutbound(createMessage("notification:push", {
    notificationType: "question", message: "Which env?", sessionId: "t2", projectId: "p1",
  }));
  d.onOutbound(createMessage("notification:push", {
    notificationType: "task_complete", message: "done", sessionId: "t1", projectId: "p1",
  }));
  expect(armed).toEqual(["t2"]);
  expect(delivered).toHaveLength(2);
});
