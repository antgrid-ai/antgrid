import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import { serviceAdapter } from "../../packages/antgrid-agents/tests/fixtures/service-adapter";
import { agentHostServices, setMemoryLaunchGate } from "../src/agent-host";
import { SessionManager } from "../src/session-manager";

// `startedWithoutMemory` is derived from what a run was actually launched with:
// the prepared launch's `memoryWithheld`, which the augmenter sets (its own
// tests cover when). Every other input is the run's lifecycle.

let dir: string;
let releaseGate: (() => void) | undefined;
beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-memory-launch-")); });
afterEach(() => {
  releaseGate?.();
  releaseGate = undefined;
  rmSync(dir, { recursive: true, force: true });
});

function harness() {
  let withheld = true;
  const live = new Set<string>();
  const runIds: string[] = [];
  const kills: string[] = [];
  let onSpawn: (() => void) | undefined;
  const definition = serviceAdapter();
  const runtime = createAgentRuntime({
    host: { ...agentHostServices, stateDirectory: () => dir },
    registry: createAgentRegistry([["service", {
      ...definition,
      create(host: Parameters<typeof definition.create>[0]) {
        const spec = definition.create(host);
        return {
          ...spec,
          prepareTerminal: async (request: Parameters<NonNullable<typeof spec.prepareTerminal>>[0]) => {
            const launch = await spec.prepareTerminal!(request);
            return withheld ? { ...launch, memoryWithheld: true as const } : launch;
          },
        };
      },
    }]]),
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
  });
  const started = async (opts: { tool?: string; command?: string } = { tool: "service" }) => {
    const s = sessions.create("s", opts);
    await sessions.start(s.id);
    return s.id;
  };
  return {
    sessions, runIds, live, kills, started,
    setOnSpawn: (fn: (() => void) | undefined) => { onSpawn = fn; },
    setWithheld: (value: boolean) => { withheld = value; },
    wire: (id: string) => sessions.list(true).find((e) => e.id === id),
  };
}

describe("startedWithoutMemory", () => {
  let h: ReturnType<typeof harness>;
  beforeEach(() => { h = harness(); });
  afterEach(() => { h.sessions.flushNow(); });

  it("is true for a launch that withheld the Memory server", async () => {
    const id = await h.started();
    expect(h.wire(id)?.startedWithoutMemory).toBe(true);
  });

  it("is absent for a launch that did not withhold it", async () => {
    h.setWithheld(false);
    const id = await h.started();
    expect(h.wire(id)?.running).toBe(true);
    expect(h.wire(id)?.startedWithoutMemory).toBeUndefined();
  });

  it("is withheld while the launch is still preparing, matching restartForMemory's refusal", async () => {
    let during: boolean | undefined;
    const s = h.sessions.create("s", { tool: "service" });
    h.setOnSpawn(() => { during = h.wire(s.id)?.startedWithoutMemory; });
    await h.sessions.start(s.id);
    expect(during).toBeUndefined();
    expect(h.wire(s.id)?.startedWithoutMemory).toBe(true);
  });

  it("stays true after the gate turns on, since the process cannot gain Memory", async () => {
    const id = await h.started();
    releaseGate = setMemoryLaunchGate(() => true);
    expect(h.wire(id)?.startedWithoutMemory).toBe(true);
  });

  it("is absent for a custom command, which never takes the agent's launch preparation", async () => {
    const id = await h.started({ command: process.execPath });
    expect(h.wire(id)?.startedWithoutMemory).toBeUndefined();
  });

  it("is absent while a scheduled run is active on the session", async () => {
    const id = await h.started();
    const scheduled = { runtimeGeneration: "g", launched: true, cancelled: false, terminal: false };
    (h.sessions as any).scheduledLaunches.set(id, scheduled);
    expect(h.wire(id)?.startedWithoutMemory).toBeUndefined();
    expect(h.sessions.listStartedWithoutMemory()).toEqual([]);

    scheduled.terminal = true;
    expect(h.wire(id)?.startedWithoutMemory).toBe(true);
  });

  it("is absent after the run stops or exits", async () => {
    const id = await h.started();
    h.sessions.stop(id);
    h.sessions.noteExited(id, h.runIds[0]);
    expect(h.wire(id)?.running).toBe(false);
    expect(h.wire(id)?.startedWithoutMemory).toBeUndefined();
    expect((h.sessions as any).terminalRunsWithoutMemory.has(id)).toBe(false);
  });

  it("is not cleared by a stale exit that arrives after a same-slot relaunch", async () => {
    const id = await h.started();
    h.sessions.stop(id);
    await h.sessions.start(id);
    expect(h.runIds.length).toBe(2);

    h.sessions.noteExited(id, h.runIds[0]);

    expect(h.wire(id)?.running).toBe(true);
    expect(h.wire(id)?.startedWithoutMemory).toBe(true);
  });

  it("is cleared by a relaunch that did not withhold it", async () => {
    const id = await h.started();
    h.sessions.stop(id);
    h.setWithheld(false);
    await h.sessions.start(id);
    expect(h.wire(id)?.startedWithoutMemory).toBeUndefined();
  });

  it("listStartedWithoutMemory returns exactly the flagged sessions", async () => {
    const flagged = await h.started();
    h.setWithheld(false);
    await h.started();
    expect(h.sessions.listStartedWithoutMemory().map((e) => e.id)).toEqual([flagged]);
    expect(h.sessions.listStartedWithoutMemory()).toEqual(h.sessions.list(false).filter((e) => e.startedWithoutMemory));
  });

  it("restartForMemory is a no-op for a run that has Memory", async () => {
    releaseGate = setMemoryLaunchGate(() => true);
    h.setWithheld(false);
    const id = await h.started();
    expect(await h.sessions.restartForMemory(id)).toBe(false);
    expect(h.kills).toEqual([]);
    expect(h.runIds.length).toBe(1);
  });

  it("is never persisted", async () => {
    const id = await h.started();
    expect(h.wire(id)?.startedWithoutMemory).toBe(true);
    h.sessions.flushNow();

    expect(readFileSync(join(dir, "agents", "p", "sessions.json"), "utf8")).not.toContain("startedWithoutMemory");
    const peeked = await SessionManager.readPersisted(dir, "p");
    expect(peeked.find((e) => e.id === id)?.startedWithoutMemory).toBeUndefined();
  });
});
