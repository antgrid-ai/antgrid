// bridge/tests/handler/runaway-guard.test.ts
import { test, expect, describe, it } from "bun:test";
import { RunawayGuard } from "../../src/handler/runaway-guard";

test("allows replies under the cap", () => {
  const g = new RunawayGuard(3);
  expect(g.check("t", "a")).toBeNull(); g.recordAutoReply("t", "a");
  expect(g.check("t", "b")).toBeNull(); g.recordAutoReply("t", "b");
});

test("blocks the (cap+1)-th consecutive auto-reply", () => {
  const g = new RunawayGuard(2);
  g.recordAutoReply("t", "a"); g.recordAutoReply("t", "b");
  expect(g.check("t", "c")).toContain("runaway");
});

test("detects a repeated (ping-pong) reply", () => {
  const g = new RunawayGuard(10);
  g.recordAutoReply("t", "same"); g.recordAutoReply("t", "other");
  expect(g.check("t", "same")).toContain("circular");
});

test("reset clears the counter and history", () => {
  const g = new RunawayGuard(2);
  g.recordAutoReply("t", "a"); g.recordAutoReply("t", "b");
  g.reset("t");
  expect(g.check("t", "c")).toBeNull();
});

test("state is per-terminal", () => {
  const g = new RunawayGuard(1);
  g.recordAutoReply("t1", "a");
  expect(g.check("t1", "b")).toContain("runaway");
  expect(g.check("t2", "b")).toBeNull();
});

describe("progress-based reset", () => {
  it("a satisfied item resets the consecutive cap but keeps circular detection", () => {
    const g = new RunawayGuard(2, 4);
    g.recordAutoReply("t", "reply-a");
    g.recordAutoReply("t", "reply-b");
    expect(g.check("t", "reply-c")).toContain("runaway cap");
    g.recordProgress("t");
    expect(g.check("t", "reply-c")).toBeNull();      // cap reset
    expect(g.check("t", "reply-a")).toContain("circular"); // hashes kept
  });
});
