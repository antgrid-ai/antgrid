// A core only answers /scheduler/* when the host handed it a scheduler, and
// even then only for a caller that is a live session; both refusals have to be
// reachable through the real ProjectCore -> agent core -> API server chain.
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { ProjectCore, type ProjectCoreDeps } from "../src/project-core";

const cleanup: Array<() => void | Promise<unknown>> = [];
const savedDir = process.env.ANTGRID_DIR;
afterEach(async () => {
  for (const fn of cleanup.splice(0).reverse()) try { await fn(); } catch {}
  if (savedDir === undefined) delete process.env.ANTGRID_DIR;
  else process.env.ANTGRID_DIR = savedDir;
});

async function startedPort(deps: Partial<ProjectCoreDeps>): Promise<number> {
  const abDir = mkdtempSync(join(tmpdir(), "antgrid-pc-sched-ab-"));
  const folder = mkdtempSync(join(tmpdir(), "antgrid-pc-sched-"));
  cleanup.push(() => rmSync(abDir, { recursive: true, force: true }));
  cleanup.push(() => rmSync(folder, { recursive: true, force: true }));
  writeFileSync(join(folder, "antgrid.yaml"), "");
  process.env.ANTGRID_DIR = abDir;
  const core = new ProjectCore({
    folder,
    mode: "local",
    identity: { deviceId: randomUUID(), deviceName: "local", createdAt: new Date().toISOString() },
    ...deps,
  });
  cleanup.push(() => core.shutdown());
  await core.start();
  return Number(readFileSync(join(abDir, "api.port"), "utf8").trim());
}

function post(port: number, body: unknown) {
  return fetch(`http://127.0.0.1:${port}/scheduler/list?terminalId=not-a-session`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

test("a core with no scheduler answers the route as unavailable", async () => {
  const port = await startedPort({});
  const res = await post(port, { runId: "r" });
  expect(res.status).toBe(503);
  expect((await res.json()).code).toBe("SCHEDULER_UNAVAILABLE");
});

test("a core with a scheduler still refuses a caller that is not a live session, without calling it", async () => {
  let called = false;
  const port = await startedPort({
    schedulerForAgent: async () => { called = true; return {}; },
  });
  const res = await post(port, { runId: "r" });
  expect(res.status).toBe(403);
  expect((await res.json()).code).toBe("NOT_A_SESSION");
  expect(called).toBe(false);
});
