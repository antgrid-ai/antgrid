import { test, expect } from "bun:test";
import { createMessage } from "../../src/protocol";
import { composePush } from "../../src/push/compose";
import { createPushDispatcher, type PushTarget } from "../../src/push/push-dispatcher";

const target: PushTarget = { pushToken: "tok", provider: "fcm", pushPubkey: "pk" };

function harness(overrides: Partial<Parameters<typeof createPushDispatcher>[0]> = {}) {
  const delivered: any[] = [];
  const sealed: string[] = [];
  const d = createPushDispatcher({
    projectId: "p1",
    shouldFallback: () => true,
    resolveTarget: () => target,
    seal: (json) => { sealed.push(json); return { epk: "E", box: "B" }; },
    deliver: (t, prov, blob) => delivered.push({ t, prov, blob }),
    ...overrides,
  });
  return { d, delivered, sealed };
}

test("composePush mirrors the app strings", () => {
  expect(composePush(createMessage("notification:push", { notificationType: "task_complete", message: "built", projectId: "p1" })))
    .toEqual({ title: "Task complete", body: "built", kind: "agent" });
  expect(composePush(createMessage("handler:escalation", {
    projectId: "p1", escalationId: "e1", terminalId: "t", question: "Deploy?", reasoning: "", draftReply: "", urgency: "high",
  }))).toEqual({ title: "Handler — urgent", body: "Deploy?", kind: "handler" });
});

test("composePush: sessionTitle becomes the title, message the body", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "task_complete", message: "Added a regression test", sessionTitle: "Fix auth bug", projectId: "p1",
  }))).toEqual({ title: "Fix auth bug", body: "Added a regression test", kind: "agent" });
});

test("composePush: sessionTitle without a message keeps the label as the body", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "task_complete", sessionTitle: "Fix auth bug", projectId: "p1",
  }))).toEqual({ title: "Fix auth bug", body: "Task complete", kind: "agent" });
});

test("composePush: neither field degrades to today's exact strings", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "task_complete", projectId: "p1",
  }))).toEqual({ title: "Task complete", body: "Task complete", kind: "agent" });
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
  }))).toEqual({ title: "Agent error", body: "Agent error", kind: "agent" });
});

test("composePush: sessionTitle titles a permission request too", () => {
  expect(composePush(createMessage("notification:push", {
    notificationType: "permission_request", message: "Run rm -rf build?", sessionTitle: "Fix auth bug", projectId: "p1",
  }))).toEqual({ title: "Fix auth bug", body: "Run rm -rf build?", kind: "agent" });
});

test("suppressed peer → seals payload and delivers", () => {
  const { d, delivered, sealed } = harness();
  d.onOutbound(createMessage("handler:escalation", {
    projectId: "p1", escalationId: "e1", terminalId: "t", question: "Deploy?", reasoning: "", draftReply: "", urgency: "normal",
  }));
  expect(delivered).toHaveLength(1);
  expect(delivered[0].t).toBe("tok");
  const payload = JSON.parse(sealed[0]);
  expect(payload).toEqual({ title: "Handler needs you", body: "Deploy?", kind: "handler", projectId: "p1", sourceMessageId: "e1" });
});

test("not suppressed (in-band available) → no delivery", () => {
  const { d, delivered } = harness({ shouldFallback: () => false });
  d.onOutbound(createMessage("notification:push", { notificationType: "idle", projectId: "p1" }));
  expect(delivered).toHaveLength(0);
});

test("no target → no delivery", () => {
  const { d, delivered } = harness({ resolveTarget: () => null });
  d.onOutbound(createMessage("notification:push", { notificationType: "error", projectId: "p1" }));
  expect(delivered).toHaveLength(0);
});

test("non-user-facing message → ignored", () => {
  const { d, delivered } = harness();
  d.onOutbound(createMessage("terminal:input", { terminalId: "t", data: "x" }));
  expect(delivered).toHaveLength(0);
});
