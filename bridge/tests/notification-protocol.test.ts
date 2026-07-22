import { test, expect } from "bun:test";
import { createMessage, parseMessage } from "../src/protocol";

test("terminal:notification round-trips through schema", () => {
  const msg = createMessage("terminal:notification", {
    terminalId: "t1",
    kind: "osc9",
    body: "Build finished",
  });
  expect(msg.type).toBe("terminal:notification");
  const parsed = parseMessage(JSON.stringify(msg));
  expect(parsed?.type).toBe("terminal:notification");
});
