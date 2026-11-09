// A chat spawn must never wait on, or fail because of, Memory's status answer.
import { test, expect } from "bun:test";
import { chatMemoryGuidance } from "../src/memory";
import { MEMORY_AGENT_GUIDANCE } from "antgrid-agents/memory-guidance";
import { MemoryError } from "antgrid-memory";

const caller = () => ({ session_id: "s", checkout_id: "main", agent_id: "claude-code", run_id: "r" });
const status = { available: true, enabled: true, paused: false, project_paused: false, secret: "x" };

test("asks for status and answers the guidance when Memory is on", async () => {
  const seen: unknown[] = [];
  const got = await chatMemoryGuidance(async (_c, req) => { seen.push(req); return status; }, caller);
  expect(seen).toEqual([{ op: "status" }]);
  expect(got).toBe(MEMORY_AGENT_GUIDANCE);
});

test("is undefined while Memory is paused", async () => {
  expect(await chatMemoryGuidance(async () => ({ ...status, project_paused: true }), caller)).toBeUndefined();
});

test("is undefined when the caller does not resolve", async () => {
  const got = await chatMemoryGuidance(async (c) => { c(); return status; }, () => {
    throw new MemoryError("NOT_A_SESSION", "no");
  });
  expect(got).toBeUndefined();
});

test("is undefined when Memory fails", async () => {
  expect(await chatMemoryGuidance(async () => { throw new Error("boom"); }, caller)).toBeUndefined();
});

test("is undefined on a malformed answer", async () => {
  expect(await chatMemoryGuidance(async () => ({ available: "yes" }), caller)).toBeUndefined();
});

test("gives up after the timeout", async () => {
  // withTimeout unrefs its timer, and Bun never fires an unref'd timer that is
  // the only thing keeping the loop alive. The bridge always has a child or a
  // socket holding it open; this stands in for that.
  const keepAlive = setInterval(() => {}, 1000);
  try {
    const t0 = Date.now();
    const got = await chatMemoryGuidance(() => new Promise(() => {}), caller, 30);
    expect(got).toBeUndefined();
    expect(Date.now() - t0).toBeLessThan(1000);
  } finally {
    clearInterval(keepAlive);
  }
});
