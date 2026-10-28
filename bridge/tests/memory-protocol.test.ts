import { expect, test } from "bun:test";
import { AbMessageSchema, CHECKOUT_VARIABLE_MESSAGE_TYPES, createMessage, parseMessage, parseMessageFast } from "../src/protocol";
import { ControlRequestSchema } from "../src/control-protocol";
import { armBodyCapture, BODY_REDACTED_MARKER, captureBody } from "../src/netwatch";

test("memory requests travel on project streams without caller-controlled project or checkout identity", () => {
  const request = createMessage("memory:request", { requestId: "read", request: { op: "get", id: "record", history: true } });
  expect(parseMessage(JSON.stringify(request))).toEqual(request);
  expect(parseMessageFast(JSON.stringify(request))).toEqual(request);
  expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has("memory:request")).toBe(false);
  expect(AbMessageSchema.safeParse({ ...request, request: { ...request.request, project_id: "foreign" } }).success).toBe(false);
  expect(ControlRequestSchema.safeParse({ id: "machine", type: "memory:request", request: { op: "status" } }).success).toBe(true);
});

test("memory payloads never enter body-capture diagnostics", () => {
  armBodyCapture(true, 1000);
  try {
    for (const frame of [
      { type: "memory:request", request: { content: "private finding" } },
      { type: "memory:result", result: { content: "private finding" } },
      { type: "request", method: "memory.request", params: { op: "export" } },
      { type: "response", result: { records: [{ memory_type: "note", content: "private finding" }] } },
    ]) expect(captureBody(JSON.stringify(frame), frame.type)).toBe(BODY_REDACTED_MARKER);
  } finally { armBodyCapture(false, 0); }
});
