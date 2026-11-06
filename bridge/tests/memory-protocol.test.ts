import { expect, test } from "bun:test";
import { AbMessageSchema, CHECKOUT_VARIABLE_MESSAGE_TYPES, createMessage, parseMessage, parseMessageFast } from "../src/protocol";
import { MemoryResultSchema } from "antgrid-memory";
import { ControlRequestSchema } from "../src/control-protocol";
import { armBodyCapture, BODY_REDACTED_MARKER, captureBody } from "../src/netwatch";

test("memory requests travel on project streams where a caller project_id can only narrow", () => {
  const request = createMessage("memory:request", { requestId: "read", request: { op: "get", id: "record", history: true } });
  expect(parseMessage(JSON.stringify(request))).toEqual(request);
  expect(parseMessageFast(JSON.stringify(request))).toEqual(request);
  expect(CHECKOUT_VARIABLE_MESSAGE_TYPES.has("memory:request")).toBe(false);
  expect(AbMessageSchema.safeParse({ ...request, request: { ...request.request, project_id: "foreign" } }).success).toBe(false);
  const list = createMessage("memory:request", { requestId: "list", request: { op: "list", project_id: "p1", versions: "all", memory_type: "note" } });
  expect(AbMessageSchema.safeParse(list).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "machine", type: "memory:request", request: { op: "status" } }).success).toBe(true);
});

test("memory results carry project rows and status failures", () => {
  const projects = { projects: [{ project_id: "p1", memories: 1, earlier_versions: 0, paused: false, label: "P", cataloged: true }], memories: 1, earlier_versions: 0 };
  expect(MemoryResultSchema.safeParse(projects).success).toBe(true);
  const status = {
    available: true, enabled: true, paused: false, search_status: "ready", recovery_status: "ready",
    pending_operations: 0, failed_operations: 1, project_paused: false,
    failures: [{ code: "CONFLICT", target_id: "m1", latest_id: "m2", project_id: "p1" }],
  };
  expect(MemoryResultSchema.safeParse(status).success).toBe(true);
  const response = createMessage("memory:result", { requestId: "p", ok: true, result: projects });
  expect(parseMessage(JSON.stringify(response))).toEqual(response);
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

test("memory export pagination is validated on project and machine request paths", () => {
  const request = createMessage("memory:request", { requestId: "export", request: { op: "export", cursor: "page-token" } });
  expect(parseMessage(JSON.stringify(request))).toEqual(request);
  expect(parseMessageFast(JSON.stringify(request))).toEqual(request);
  expect(ControlRequestSchema.safeParse({ id: "machine", type: "memory:request", request: request.request }).success).toBe(true);
  for (const cursor of [42, "", "a".repeat(2049)]) {
    const invalid = { op: "export", cursor };
    expect(AbMessageSchema.safeParse({ ...request, request: invalid }).success).toBe(false);
    expect(ControlRequestSchema.safeParse({ id: "machine", type: "memory:request", request: invalid }).success).toBe(false);
  }
  const response = createMessage("memory:result", { requestId: "export", ok: true, result: {
    version: 1, owner_id: "owner", exported_at: 1000, records: [], next_cursor: null,
  } });
  expect(parseMessage(JSON.stringify(response))).toEqual(response);
  expect(parseMessage(JSON.stringify({ ...response, result: { ...response.result, next_cursor: 42 } }))).toBeNull();
});
