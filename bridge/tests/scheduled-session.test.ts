import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { agentRuntime } from "../src/agent-runtime";
import { SessionManager, type ScheduledSessionObservation, type ScheduledSessionSpec } from "../src/session-manager";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import type { CheckoutRecord, CheckoutSetupProgress } from "../src/worktrees/checkout-types";
import type { TerminalLaunchRequest } from "antgrid-agents/contracts";
import type { WorktreeManager, PrepareWorktreeArgs } from "../src/worktrees/worktree-manager";
import { schedulingModesForAgent } from "antgrid-agents/builtins";

let root: string;
let store: CheckoutStore;
let managers: SessionManager[];
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "antgrid-scheduled-session-"));
  store = new CheckoutStore(root, "p");
  managers = [];
});
afterEach(() => {
  for (const manager of managers) manager.flushNow();
  rmSync(root, { recursive: true, force: true });
});

const spec: ScheduledSessionSpec = {
  scheduleId: "daily", name: "Daily review", agentId: "codex", mode: "terminal",
  approvalPolicy: "default", workspace: "worktree",
};

function fixture(options: { setup?: boolean; monitoring?: boolean; launchFailure?: boolean; creationGate?: Promise<void>; onCreation?: () => void } = {}) {
  const requests: TerminalLaunchRequest[] = [];
  const spawns: any[] = [];
  const live = new Set<string>();
  const observations: ScheduledSessionObservation[] = [];
  let creations = 0;
  let removals = 0;
  let setupRuns = 0;
  let cancelledSetups = 0;
  let progress: ((progress: CheckoutSetupProgress) => void) | undefined;
  const terminal = {
    spawn: (config: any) => { spawns.push(config); live.add(config.terminalId); return config.terminalId; },
    kill: (id: string) => live.delete(id), forget: (id: string) => live.delete(id),
    has: (id: string) => live.has(id), treeKilled: async () => {},
  };
  const worktrees = {
    prepareForSession: async (args: PrepareWorktreeArgs): Promise<CheckoutRecord> => {
      creations++;
      options.onCreation?.();
      await options.creationGate;
      const path = join(root, "wt", `checkout-${creations}`);
      mkdirSync(path, { recursive: true });
      const record: CheckoutRecord = {
        id: `checkout-${creations}`, projectId: "p", kind: "managed-worktree", path,
        managed: true, branch: "antgrid/daily", baseRef: args.baseBranch ?? null,
        sessionId: args.sessionId, scheduleOwnerId: args.scheduleOwnerId, createdAt: 1,
      };
      await store.put(record);
      return record;
    },
    rollbackPrepared: async () => {},
    recordFor: async (_projectId: string, checkoutId: string) => store.get(checkoutId),
    inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
    remove: async () => { removals++; },
  } as unknown as WorktreeManager;
  const runtime = {
    ...agentRuntime,
    prepareTerminal: (request: TerminalLaunchRequest) => {
      requests.push(request);
      if (options.launchFailure) throw new Error("Provider launch failed");
      return {
        command: "fake-agent", invocationKind: "exec" as const, args: [request.initialPrompt ?? ""], env: {},
        resumed: false, promptDelivery: "included" as const,
        observation: { notifications: true, titles: true, handler: true, turnStart: true, turnEnd: options.monitoring !== false, hookAlive: true },
      };
    },
  };
  const createManager = () => {
    const manager = new SessionManager({
      projectId: "p", projectPath: root, storeDir: root, terminalManager: terminal as any,
      agentSpec: { command: "codex", name: "codex" }, agentRuntime: runtime, sendMessage: () => {},
      worktreeManager: worktrees, worktreeSessionsSupported: true, isGitRepository: async () => true,
      prepareCheckoutRuntime: async () => {}, resolveCheckout: (id) => store.get(id),
      checkoutSetupPolicy: () => ({ declares: !!options.setup, startAgent: "afterSetup" }),
      ...(options.setup ? { runCheckoutSetup: (_checkout: CheckoutRecord, _sessionId: string, callback: typeof progress) => { setupRuns++; progress = callback; } } : {}),
      cancelCheckoutSetup: async () => { cancelledSetups++; },
      onScheduledObservation: (event) => observations.push(event),
    });
    managers.push(manager);
    return manager;
  };
  return { createManager, requests, spawns, live, observations,
    creations: () => creations, removals: () => removals, setupRuns: () => setupRuns,
    cancelledSetups: () => cancelledSetups,
    finishSetup: (state: "done" | "failed" = "done") => progress?.({ state, stepIndex: 0, stepCount: 1 }),
  };
}

describe("scheduled fresh session launch", () => {
  test("persists association before preparation or prompt dispatch and refuses duplicate dispatch", async () => {
    const f = fixture();
    const manager = f.createManager();
    let bound = false;
    const prepared = await manager.prepareScheduledSession(spec, async (identity) => {
      expect(f.spawns).toHaveLength(0);
      expect(f.requests).toHaveLength(0);
      expect(manager.get(identity.sessionId)?.checkoutId).toBe(identity.checkoutId);
      expect((await store.get(identity.checkoutId))?.scheduleOwnerId).toBe(spec.scheduleId);
      bound = true;
    });
    expect(bound).toBe(true);
    await expect(Promise.resolve(manager.start(prepared.sessionId))).rejects.toThrow("still preparing");
    await prepared.deliverPrompt("Review the changes");
    expect(f.requests[0]?.conversation.kind).toBe("fresh");
    expect(f.requests[0]?.approvalPolicy).toBe("default");
    expect(f.spawns[0]?.env.ANTGRID_RUN_ID).toBe(prepared.runtimeGeneration);
    await expect(prepared.deliverPrompt("Review again")).rejects.toThrow("already dispatched");
  });

  test("uses explicit events, ignores old generations and preserves the completed session", async () => {
    const f = fixture();
    const manager = f.createManager();
    const prepared = await manager.prepareScheduledSession(spec, async () => {});
    await prepared.deliverPrompt("Review");
    manager.observeScheduledSession(prepared.sessionId, "old-generation", "completed");
    f.requests[0]!.scope.emit({ type: "notification", notificationType: "idle", message: "Idle" });
    expect(f.observations.map((event) => event.status)).toEqual(["running"]);
    f.requests[0]!.scope.emit({ type: "notification", notificationType: "permission_request", message: "Approve" });
    f.requests[0]!.scope.emit({ type: "turn-start" });
    f.requests[0]!.scope.emit({ type: "handler", event: "turn_end" });
    expect(f.observations.map((event) => event.status)).toEqual(["running", "needs-input", "running", "completed"]);
    expect(manager.get(prepared.sessionId)?.running).toBe(true);
    f.requests[0]!.scope.emit({ type: "turn-start" });
    manager.noteExited(prepared.sessionId, prepared.runtimeGeneration);
    expect(f.observations.at(-1)?.status).toBe("completed");
  });

  test("reuses the owned workspace after all sessions are deleted and the bridge restarts", async () => {
    const f = fixture();
    const manager = f.createManager();
    const first = await manager.prepareScheduledSession(spec, async () => {});
    const record = (await store.get(first.checkoutId))!;
    writeFileSync(join(record.path, "accumulated.txt"), "uncommitted schedule work");
    expect(manager.get(first.sessionId)?.sharedWorkspace).toBe(true);
    await manager.delete(first.sessionId, { force: true, deleteBranch: true });
    expect(f.removals()).toBe(0);
    expect((await store.get(first.checkoutId))?.sessionId).toBeNull();
    expect(existsSync(record.path)).toBe(true);
    const restarted = f.createManager();
    const second = await restarted.prepareScheduledSession({ ...spec, checkoutId: first.checkoutId }, async () => {});
    expect(second.sessionId).not.toBe(first.sessionId);
    expect(second.checkoutId).toBe(first.checkoutId);
    expect(f.creations()).toBe(1);
    expect(readFileSync(join(record.path, "accumulated.txt"), "utf8")).toBe("uncommitted schedule work");
    await restarted.releaseScheduleCheckout(spec.scheduleId, first.checkoutId);
    expect((await store.get(first.checkoutId))?.scheduleOwnerId).toBeUndefined();
    await restarted.delete(second.sessionId);
    expect(f.removals()).toBe(1);
  });

  test("recovers an owned checkout when association storage failed without submitting uncertain work", async () => {
    const f = fixture();
    const manager = f.createManager();
    await expect(manager.prepareScheduledSession(spec, async () => { throw new Error("SQLite failure"); })).rejects.toThrow("SQLite failure");
    expect(f.spawns).toHaveLength(0);
    const prepared = await f.createManager().prepareScheduledSession(spec, async () => {});
    expect(f.creations()).toBe(1);
    expect(prepared.checkoutId).toBe("checkout-1");
    expect(f.spawns).toHaveLength(0);
  });

  test("serializes preparation before ownership exists and reuses a stopped launch's checkout", async () => {
    let releaseCreation!: () => void;
    let enteredCreation!: () => void;
    const creationGate = new Promise<void>((resolve) => { releaseCreation = resolve; });
    const creationEntered = new Promise<void>((resolve) => { enteredCreation = resolve; });
    const f = fixture({ creationGate, onCreation: enteredCreation });
    const manager = f.createManager();
    const first = manager.prepareScheduledSession(spec, async () => { throw new Error("Stopped before binding"); }).catch((error: Error) => error);
    await creationEntered;
    const second = manager.prepareScheduledSession(spec, async () => {});
    expect(f.creations()).toBe(1);
    releaseCreation();
    expect((await first as Error).message).toBe("Stopped before binding");
    expect((await second).checkoutId).toBe("checkout-1");
    expect(f.creations()).toBe(1);
    expect(f.spawns).toHaveLength(0);
  });

  test("a refused bind cancels already-started setup and retains partial provisioning for repair", async () => {
    const f = fixture({ setup: true });
    const manager = f.createManager();
    await expect(manager.prepareScheduledSession(spec, async () => { throw new Error("Stopped before binding"); })).rejects.toThrow("Stopped before binding");
    expect(f.cancelledSetups()).toBe(1);
    expect((await store.get("checkout-1"))?.setupState).toBe("failed");
    await expect(manager.prepareScheduledSession(spec, async () => {})).rejects.toMatchObject({ code: "SETUP_FAILED" });
    expect(f.creations()).toBe(1);
    expect(f.setupRuns()).toBe(1);
    expect(f.spawns).toHaveLength(0);
  });

  test("binds before setup, awaits provisioning before returning, and provisions only once", async () => {
    const f = fixture({ setup: true });
    const manager = f.createManager();
    let associated = false;
    let associatedNow!: () => void;
    const association = new Promise<void>((resolve) => { associatedNow = resolve; });
    let returned = false;
    const preparing = manager.prepareScheduledSession(spec, async () => { associated = true; associatedNow(); }).then((value) => { returned = true; return value; });
    await association;
    expect(associated).toBe(true);
    expect(returned).toBe(false);
    expect(f.spawns).toHaveLength(0);
    f.finishSetup();
    const first = await preparing;
    expect((await store.get(first.checkoutId))?.setupState).toBe("done");
    await first.deliverPrompt("Review");
    f.requests[0]!.scope.emit({ type: "handler", event: "turn_end" });
    await f.createManager().prepareScheduledSession({ ...spec, checkoutId: first.checkoutId }, async () => {});
    expect(f.setupRuns()).toBe(1);
  });

  test("stopping preparation cancels setup and never delivers its prompt", async () => {
    const f = fixture({ setup: true });
    const manager = f.createManager();
    let sessionId = "";
    let associatedNow!: () => void;
    const association = new Promise<void>((resolve) => { associatedNow = resolve; });
    const preparing = manager.prepareScheduledSession(spec, async (identity) => { sessionId = identity.sessionId; associatedNow(); });
    await association;
    const rejected = preparing.catch((error: Error) => error);
    await manager.stopScheduledSession(sessionId);
    expect((await rejected as Error).message).toContain("cancelled");
    expect(f.spawns).toHaveLength(0);
    expect(f.observations.at(-1)?.status).toBe("interrupted");
  });

  test("missing workspaces fail without substitution or another setup run", async () => {
    const f = fixture();
    const manager = f.createManager();
    const first = await manager.prepareScheduledSession(spec, async () => {});
    rmSync((await store.get(first.checkoutId))!.path, { recursive: true, force: true });
    await expect(manager.prepareScheduledSession({ ...spec, checkoutId: first.checkoutId }, async () => {})).rejects.toThrow("workspace is missing");
    expect(f.creations()).toBe(1);
    expect(f.spawns).toHaveLength(0);
  });

  test("active cancellation stops the runtime and later manual turns cannot change its recorded result", async () => {
    const f = fixture();
    const manager = f.createManager();
    const prepared = await manager.prepareScheduledSession(spec, async () => {});
    await prepared.deliverPrompt("Review");
    await manager.stopScheduledSession(prepared.sessionId);
    expect(manager.get(prepared.sessionId)?.running).toBe(false);
    expect(f.observations.at(-1)).toMatchObject({ status: "interrupted", reason: "Stopped by user" });
    await manager.start(prepared.sessionId, "Follow up manually");
    expect(f.requests.at(-1)?.scope.runId).not.toBe(prepared.runtimeGeneration);
    f.requests.at(-1)!.scope.emit({ type: "handler", event: "turn_end" });
    expect(f.observations.at(-1)?.status).toBe("interrupted");
  });

  test("unreadable checkout storage prevents dispatch and duplicate workspace creation", async () => {
    const f = fixture();
    const manager = f.createManager();
    const prepared = await manager.prepareScheduledSession(spec, async () => {});
    writeFileSync(join(root, "agents", "p", "checkouts.json"), "corrupted");
    await expect(manager.prepareScheduledSession({ ...spec, checkoutId: prepared.checkoutId }, async () => {}))
      .rejects.toMatchObject({ code: "CHECKOUT_STORE_UNAVAILABLE" });
    expect(f.creations()).toBe(1);
    expect(f.spawns).toHaveLength(0);
  });

  test("refuses absent completion monitoring before spawning and surfaces launch failures", async () => {
    const f = fixture({ monitoring: false });
    const manager = f.createManager();
    const first = await manager.prepareScheduledSession(spec, async () => {});
    await expect(first.deliverPrompt("Review")).rejects.toThrow("completion monitoring");
    expect(f.spawns).toHaveLength(0);
    expect(f.observations).toHaveLength(0);
    const failing = fixture({ launchFailure: true });
    const second = await failing.createManager().prepareScheduledSession(spec, async () => {});
    await expect(second.deliverPrompt("Review")).rejects.toThrow("Provider launch failed");
    expect(failing.spawns).toHaveLength(0);
    expect(failing.observations).toHaveLength(0);
  });

  test("capability excludes terminal agents without both delivery and completion", () => {
    expect(schedulingModesForAgent("codex")).toEqual(["terminal", "chat"]);
    expect(schedulingModesForAgent("antigravity")).toEqual([]);
    expect(schedulingModesForAgent("github-copilot")).toEqual([]);
    expect(schedulingModesForAgent("cursor-agent")).toEqual([]);
    expect(schedulingModesForAgent("unknown")).toEqual([]);
  });
});
