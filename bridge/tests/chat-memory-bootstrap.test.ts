// A chat spawn must never wait on, or fail because of, Memory's status answer.
import { test, expect } from "bun:test";
import { chatMemoryBootstrap } from "../src/agent-core";
import { MemoryError } from "antgrid-memory";

const caller = () => ({ session_id: "s", checkout_id: "main", agent_id: "claude-code", run_id: "r" });
const status = { available: true, enabled: true, paused: false, project_paused: false, secret: "x" };

test("returns only the settings flags from a status answer", async () => {
  const seen: unknown[] = [];
  const got = await chatMemoryBootstrap(async (_c, req) => { seen.push(req); return status; }, caller);
  expect(seen).toEqual([{ op: "status" }]);
  expect(got).toEqual({ available: true, enabled: true, paused: false, project_paused: false });
});

test("is undefined when the caller does not resolve", async () => {
  const got = await chatMemoryBootstrap(async (c) => { c(); return status; }, () => {
    throw new MemoryError("NOT_A_SESSION", "no");
  });
  expect(got).toBeUndefined();
});

test("is undefined when Memory fails", async () => {
  expect(await chatMemoryBootstrap(async () => { throw new Error("boom"); }, caller)).toBeUndefined();
});

test("is undefined on a malformed answer", async () => {
  expect(await chatMemoryBootstrap(async () => ({ available: "yes" }), caller)).toBeUndefined();
});

test("gives up after the timeout", async () => {
  const t0 = Date.now();
  const got = await chatMemoryBootstrap(() => new Promise(() => {}), caller, 30);
  expect(got).toBeUndefined();
  expect(Date.now() - t0).toBeLessThan(1000);
});
