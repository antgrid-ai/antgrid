import { expect, test } from "bun:test";
import { startApiServer } from "../src/api-server";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("all hook channels discard old and unversioned posts after a run replacement", async () => {
  let currentRun = "first";
  const previousDir = process.env.ANTGRID_DIR;
  const directory = mkdtempSync(join(tmpdir(), "hook-run-test-"));
  process.env.ANTGRID_DIR = directory;
  const seen: unknown[] = [];
  const server = startApiServer({
    manager: () => null,
    config: () => ({} as any),
    project: () => ({ id: "project", path: "/tmp" } as any),
    acceptsHookRun: (terminalId, runId) => terminalId === "terminal" && runId === currentRun,
    sendAb: (body) => { seen.push(body); },
    onSessionTitle: (body) => { seen.push(body); },
    onHandlerEvent: (body) => { seen.push(body); },
    onTurnStart: (id) => { seen.push(id); },
    onHookAlive: (id) => { seen.push(id); },
  });
  const routes = [
    ["/notify", { type: "task_complete" }],
    ["/session-title", { sessionId: "native" }],
    ["/handler-event", { event: "turn_end" }],
    ["/turn-start", {}],
    ["/hook-alive", {}],
  ] as const;
  try {
    currentRun = "replacement";
    for (const [route, payload] of routes) {
      for (const runId of [undefined, "first", currentRun]) {
        const before = seen.length;
        const response = await fetch(`http://127.0.0.1:${server.port}${route}`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ ...payload, terminalId: "terminal", runId }),
        });
        expect(response.status).toBe(200);
        expect(seen.length - before).toBe(runId === currentRun ? 1 : 0);
      }
    }
  } finally {
    server.stop();
    if (previousDir === undefined) delete process.env.ANTGRID_DIR;
    else process.env.ANTGRID_DIR = previousDir;
    rmSync(directory, { recursive: true, force: true });
  }
});
