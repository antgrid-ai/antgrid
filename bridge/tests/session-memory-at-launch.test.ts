import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import { NO_INJECTION } from "antgrid-agents/launch-inject";
import { serviceAdapter } from "../../packages/antgrid-agents/tests/fixtures/service-adapter";
import { agentHostServices } from "../src/agent-host";
import { SessionManager } from "../src/session-manager";

// `startedWithoutMemory` is derived from what a run was actually launched with,
// so the launch env is the only input that matters: a prepared launch carrying
// ANTGRID_MEMORY_MCP means the MCP profile was handed over, and the gate says
// whether its absence is a choice or a soft failure.

let dir: string;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-memory-launch-")); });
afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

function harness(opts: { augmentsDefaultSpec?: true } = {}) {
  let marker: string | undefined;
  let gateOn = false;
  const live = new Set<string>();
  const runIds: string[] = [];
  const kills: string[] = [];
  let onSpawn: (() => void) | undefined;
  const definition = serviceAdapter();
  const withMcp = (name: string, mcp: boolean) => ({
    ...definition,
    hookName: name,
    create(host: Parameters<typeof definition.create>[0]) {
      const spec = definition.create(host);
      return {
        ...spec,
        hookName: name,
        ...(mcp ? { mcp: { inject: () => NO_INJECTION }, ...(opts.augmentsDefaultSpec ? { augmentsDefaultSpec: true as const } : {}) } : {}),
        prepareTerminal: async (request: Parameters<NonNullable<typeof spec.prepareTerminal>>[0]) => {
          const launch = await spec.prepareTerminal!(request);
          return { ...launch, env: { ...launch.env, ...(marker ? { ANTGRID_MEMORY_MCP: marker } : {}) } };
        },
      };
    },
  });
  const runtime = createAgentRuntime({
    host: { ...agentHostServices, stateDirectory: () => dir },
    registry: createAgentRegistry([["service", withMcp("fixture-service", true)], ["plain", withMcp("fixture-plain", false)]]),
  });
  const tm = {
    spawn: (cfg: { terminalId: string; env: Record<string, string> }) => {
      live.add(cfg.terminalId);
      runIds.push(cfg.env.ANTGRID_RUN_ID);
      onSpawn?.();
    },
    has: (id: string) => live.has(id),
    kill: (id: string) => { kills.push(id); live.delete(id); },
    treeKilled: async () => {},
    getScrollback: () => null,
    submit: () => {},
  };
  const sessions = new SessionManager({
    agentRuntime: runtime, projectId: "p", projectPath: dir, storeDir: dir,
    terminalManager: tm as never, agentSpec: { name: "service", command: "" }, sendMessage: () => {},
    memoryLaunchEnabled: () => gateOn,
  });
  return {
    sessions, runIds, live, kills,
    setOnSpawn: (fn: (() => void) | undefined) => { onSpawn = fn; },
    setMarker: (value: string | undefined) => { marker = value; },
    setGate: (on: boolean) => { gateOn = on; },
    wire: (id: string) => sessions.list(true).find((e) => e.id === id),
  };
}

describe("startedWithoutMemory", () => {
  it("is absent when the launch was handed the Memory server", async () => {
    const h = harness();
    h.setMarker("1");
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    expect(h.wire(s.id)?.running).toBe(true);
    expect(h.wire(s.id)?.startedWithoutMemory).toBeUndefined();
    h.sessions.flushNow();
  });

  it("is withheld while the launch is still preparing, matching restartForMemory's refusal", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    let during: boolean | undefined;
    h.setOnSpawn(() => { during = h.wire(s.id)?.startedWithoutMemory; });
    await h.sessions.start(s.id);
    expect(during).toBeUndefined();
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();
  });

  it("is true when the gate was off at launch", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();
  });

  it("stays true after the gate turns on, since the process cannot gain Memory", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    h.setGate(true);
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();
  });

  it("is absent when the gate was on but the profile failed soft", async () => {
    const h = harness();
    h.setGate(true);
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    expect(h.wire(s.id)?.startedWithoutMemory).toBeUndefined();
    h.sessions.flushNow();
  });

  it("restartForMemory is a no-op for a run launched with Memory", async () => {
    const h = harness();
    h.setMarker("1");
    h.setGate(true);
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    expect(await h.sessions.restartForMemory(s.id)).toBe(false);
    expect(h.kills).toEqual([]);
    expect(h.runIds.length).toBe(1);
    h.sessions.flushNow();
  });

  it("is absent for an agent with no MCP profile", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "plain" });
    await h.sessions.start(s.id);
    expect(h.wire(s.id)?.startedWithoutMemory).toBeUndefined();
    h.sessions.flushNow();
  });

  it("is absent for a custom command", async () => {
    const h = harness();
    const s = h.sessions.create("s", { command: process.execPath });
    await h.sessions.start(s.id);
    expect(h.wire(s.id)?.startedWithoutMemory).toBeUndefined();
    h.sessions.flushNow();
  });

  it("is absent for a default-spec session unless the agent augments its default spec", async () => {
    const plain = harness();
    const a = plain.sessions.create("s");
    await plain.sessions.start(a.id);
    expect(plain.wire(a.id)?.startedWithoutMemory).toBeUndefined();
    plain.sessions.flushNow();

    const augmenting = harness({ augmentsDefaultSpec: true });
    const b = augmenting.sessions.create("s");
    await augmenting.sessions.start(b.id);
    expect(augmenting.wire(b.id)?.startedWithoutMemory).toBe(true);
    augmenting.sessions.flushNow();
  });

  it("is absent while a scheduled run is active on the session", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    const scheduled = { runtimeGeneration: "g", launched: true, cancelled: false, terminal: false };
    (h.sessions as any).scheduledLaunches.set(s.id, scheduled);
    expect(h.wire(s.id)?.startedWithoutMemory).toBeUndefined();

    scheduled.terminal = true;
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();
  });

  it("is absent after the run stops or exits", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    h.sessions.stop(s.id);
    h.sessions.noteExited(s.id, h.runIds[0]);
    expect(h.wire(s.id)?.running).toBe(false);
    expect(h.wire(s.id)?.startedWithoutMemory).toBeUndefined();
    expect((h.sessions as any).terminalRunMemory.has(s.id)).toBe(false);
    h.sessions.flushNow();
  });

  it("is not cleared by a stale exit that arrives after a same-slot relaunch", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    h.sessions.stop(s.id);
    await h.sessions.start(s.id);
    expect(h.runIds.length).toBe(2);

    h.sessions.noteExited(s.id, h.runIds[0]);

    expect(h.wire(s.id)?.running).toBe(true);
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();
  });

  it("is never persisted", async () => {
    const h = harness();
    const s = h.sessions.create("s", { tool: "service" });
    await h.sessions.start(s.id);
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();

    expect(readFileSync(join(dir, "agents", "p", "sessions.json"), "utf8")).not.toContain("startedWithoutMemory");
    const peeked = await SessionManager.readPersisted(dir, "p");
    expect(peeked.find((e) => e.id === s.id)?.startedWithoutMemory).toBeUndefined();
  });
});
