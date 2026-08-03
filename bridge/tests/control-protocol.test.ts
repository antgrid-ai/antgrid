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

// Mobile authorization is one machine-wide switch, so there is no per-phone
// grant verb any more. An old app still sending one must fail the parse rather
// than fall through to some other branch.
test("the retired per-phone allowlist verbs no longer parse", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:allow", phonePubkey: "pk", projectId: "p1" }).success).toBe(false);
  expect(ControlRequestSchema.safeParse({ id: "2", type: "phones:deny", phonePubkey: "pk", projectId: "p1" }).success).toBe(false);
});

test("phones:unpair requires phonePubkey", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:unpair", phonePubkey: "pk" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "1", type: "phones:unpair" }).success).toBe(false);
});

test("mobile-access:set carries the machine-wide boolean", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "mobile-access:get" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "2", type: "mobile-access:set", enabled: true }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "3", type: "mobile-access:set", enabled: false }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "4", type: "mobile-access:set" }).success).toBe(false);
  // The per-project verbs it replaced are gone, not aliased.
  expect(ControlRequestSchema.safeParse({ id: "5", type: "mobile-access:enable-project", projectId: "projA" }).success).toBe(false);
  expect(ControlRequestSchema.safeParse({ id: "6", type: "mobile-access:disable-project", projectId: "projA" }).success).toBe(false);
});

test("git:branches accepts valid request", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "git:branches", projectId: "p1", projectPath: "/path" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "2", type: "git:branches", projectId: "p1" }).success).toBe(false);
});

test("git:checkout accepts valid request with optional allowActiveSessions", () => {
  expect(ControlRequestSchema.safeParse({ id: "1", type: "git:checkout", projectId: "p1", projectPath: "/path", branch: "dev" }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "2", type: "git:checkout", projectId: "p1", projectPath: "/path", branch: "dev", allowActiveSessions: true }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "3", type: "git:checkout", projectId: "p1", projectPath: "/path", branch: "dev", allowActiveSessions: false }).success).toBe(true);
  expect(ControlRequestSchema.safeParse({ id: "4", type: "git:checkout", projectId: "p1", projectPath: "/path" }).success).toBe(false);
});
