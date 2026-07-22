import { test, expect } from "bun:test";
import { createMessage, parseMessage } from "../../src/protocol";

test("handler:configure round-trips through parseMessage", () => {
  const m = createMessage("handler:configure", {
    projectId: "p1", enabled: true, template: "closer", model: "haiku",
  });
  const parsed = parseMessage(JSON.stringify(m));
  expect(parsed).not.toBeNull();
  expect(parsed!.type).toBe("handler:configure");
  expect((parsed as any).template).toBe("closer");
});

test("handler:escalation round-trips with all fields", () => {
  const m = createMessage("handler:escalation", {
    projectId: "p1", escalationId: "e1", terminalId: "t1",
    question: "bun or vitest?", reasoning: "architecture call", draftReply: "use bun", urgency: "normal",
  });
  const parsed = parseMessage(JSON.stringify(m));
  expect((parsed as any).draftReply).toBe("use bun");
});

test("handler:configure rejects an unknown template", () => {
  // Valid uuid + timestamp so the ONLY failing constraint is the template enum.
  // (BaseMessage.id is z.string().uuid(); a junk id would make this pass for the
  // wrong reason — i.e. it would still pass even if the template enum were broken.)
  const bad = JSON.stringify({
    id: "00000000-0000-4000-8000-000000000000", timestamp: 1,
    type: "handler:configure", projectId: "p", enabled: true, template: "nope",
  });
  expect(parseMessage(bad)).toBeNull();
});
