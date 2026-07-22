import { expect, test } from "bun:test";
import { createMessage, parseMessage, parseMessageFast } from "../src/protocol";

test("agent:request-retracted round-trips with a permissionId", () => {
  const msg = createMessage("agent:request-retracted", {
    sessionId: "s1",
    permissionId: "perm-0",
  });
  const parsed = parseMessage(JSON.stringify(msg));
  expect(parsed?.type).toBe("agent:request-retracted");
  if (parsed?.type === "agent:request-retracted") {
    expect(parsed.permissionId).toBe("perm-0");
    expect(parsed.questionId).toBeUndefined();
  }
});

test("agent:request-retracted passes parseMessageFast (KNOWN_TYPES)", () => {
  const msg = createMessage("agent:request-retracted", {
    sessionId: "s1",
    questionId: "q-1",
  });
  const parsed = parseMessageFast(JSON.stringify(msg));
  expect(parsed?.type).toBe("agent:request-retracted");
});
