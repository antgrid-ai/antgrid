// bridge/tests/protocol-terminal-size.test.ts
import { test, expect } from "bun:test";
import { parseMessage, createMessage } from "../src/protocol";

// Nil UUID satisfies BaseMessage.id's z.string().uuid() validation.
const ID = "00000000-0000-0000-0000-000000000000";

test("terminal:resize carries clientId", () => {
  const msg = parseMessage(JSON.stringify({
    type: "terminal:resize", intent: "resize",
    id: ID, timestamp: 1,
    terminalId: "t1", cols: 80, rows: 24, clientId: "dev-abc",
  }));
  expect(msg).not.toBeNull();
  expect(msg!.type).toBe("terminal:resize");
  // @ts-expect-error narrow at runtime
  expect(msg!.clientId).toBe("dev-abc");
});

test("terminal:size round-trips through createMessage + parseMessage", () => {
  const built = createMessage("terminal:size", {
    terminalId: "t1", cols: 100, rows: 30, driverClientId: "dev-abc",
  });
  const parsed = parseMessage(JSON.stringify(built));
  expect(parsed).not.toBeNull();
  expect(parsed!.type).toBe("terminal:size");
  // @ts-expect-error narrow at runtime
  expect(parsed!.driverClientId).toBe("dev-abc");
});


test("resize requires an explicit recognized intent", () => {
  const payload = { type: "terminal:resize", id: ID, timestamp: 1,
    terminalId: "t1", cols: 80, rows: 24, clientId: "viewer" };
  expect(parseMessage(JSON.stringify(payload))).toBeNull();
  expect(parseMessage(JSON.stringify({ ...payload, intent: "focus" }))).toBeNull();
  expect(parseMessage(JSON.stringify({ ...payload, intent: "takeover" }))).not.toBeNull();
});
