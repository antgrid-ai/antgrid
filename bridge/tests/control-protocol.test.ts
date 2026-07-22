import { test, expect } from "bun:test";
import { ControlRequestSchema } from "../src/control-protocol";

test("accepts a valid project:list request", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "project:list" }).success).toBe(true);
});

test("accepts a valid project:open request", () => {
  const r = ControlRequestSchema.safeParse({ id: "2", type: "project:open", projectId: "p", projectPath: "/tmp/p", mode: "local" });
  expect(r.success).toBe(true);
});

test("rejects project:open missing projectPath", () => {
  expect(ControlRequestSchema.safeParse({ id: "3", type: "project:open", projectId: "p" }).success).toBe(false);
});

test("accepts a project:open request with mode", () => {
  const r = ControlRequestSchema.safeParse({ id: "2", type: "project:open", projectId: "p", projectPath: "/tmp/p", mode: "local" });
  expect(r.success).toBe(true);
});

test("rejects project:open missing mode", () => {
  expect(ControlRequestSchema.safeParse({ id: "3", type: "project:open", projectId: "p", projectPath: "/tmp/p" }).success).toBe(false);
});

test("rejects project:open with a bogus mode", () => {
  expect(ControlRequestSchema.safeParse({ id: "4", type: "project:open", projectId: "p", projectPath: "/tmp/p", mode: "sideways" }).success).toBe(false);
});

test("rejects an unknown verb", () => {
  expect(ControlRequestSchema.safeParse({ id: "4", type: "project:nuke" }).success).toBe(false);
});

test("rejects a request missing id", () => {
  expect(ControlRequestSchema.safeParse({ type: "project:list" }).success).toBe(false);
});

test("phones:list parses with only id+type", () => {
  const r = ControlRequestSchema.safeParse({ id: "1", type: "phones:list" });
  expect(r.success).toBe(true);
});

test("phones:allow requires phonePubkey + projectId", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:allow", phonePubkey: "pk", projectId: "p1" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:allow", phonePubkey: "pk" }).success).toBe(false);
});

test("phones:unpair requires phonePubkey", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:unpair", phonePubkey: "pk" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:unpair" }).success).toBe(false);
});

test("mobile-access verbs validate project defaults requests", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "mobile-access:get" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "2", type: "mobile-access:enable-project", projectId: "projA" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "3", type: "mobile-access:disable-project", projectId: "projA" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "4", type: "mobile-access:enable-project" }).success).toBe(false);
});
