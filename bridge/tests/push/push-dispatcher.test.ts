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
