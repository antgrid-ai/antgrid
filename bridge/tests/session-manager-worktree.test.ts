import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import type { CheckoutRecord, CheckoutSetupProgress } from "../src/worktrees/checkout-types";
import type { WorktreeManager } from "../src/worktrees/worktree-manager";

function fakeTerminal() {
  const running = new Set<string>();
  const spawns: Array<{ terminalId: string; cwd?: string; args?: string[] }> = [];
  return {
    spawn: (opts: { terminalId: string; cwd?: string; args?: string[] }) => {
      running.add(opts.terminalId);
      spawns.push({ terminalId: opts.terminalId, cwd: opts.cwd, args: opts.args });
      return opts.terminalId;
    },
    kill: (id: string) => running.delete(id),
    forget: (id: string) => running.delete(id),
    treeKilled: () => Promise.resolve(),
    has: (id: string) => running.has(id),
    spawns,
  };
}

describe("isolated SessionManager creation", () => {
  it("commits a checkout binding only after the runtime is prepared", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    const calls: string[] = [];
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: join(dir, "wt"),
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => { calls.push("rollback"); },
      recordFor: async () => ({ id: "checkout-1" } as CheckoutRecord),
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => { calls.push("remove"); },
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
        agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        prepareCheckoutRuntime: async () => { calls.push("runtime"); },
        teardownCheckoutRuntime: async () => { calls.push("teardown"); },
        resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
      });
      const created = await sm.create("Isolated", { isolation: "worktree", baseBranch: "main" });
      expect(calls).toEqual(["runtime"]);
      expect(created.checkoutId).toBe("checkout-1");
      expect(created.checkoutKind).toBe("managed-worktree");
      expect(sm.list()).toHaveLength(1);
      await sm.delete(created.id);
      // Teardown BEFORE remove: the runtime's service PTYs and file watcher hold
      // the very directory Git is about to delete (a sharing violation on
      // Windows), so their order is load-bearing, not incidental.
      expect(calls).toEqual(["runtime", "teardown", "remove"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("re-pushes the checkout's workspace state after the session is announced", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    const order: string[] = [];
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: join(dir, "wt"),
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => ({ id: "checkout-1" } as CheckoutRecord),
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
        agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        prepareCheckoutRuntime: async () => { order.push("prepare"); },
        announceCheckoutRuntime: (id) => { order.push(`announce:${id}`); },
        resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
      });
      sm.onChange(() => order.push(`sessions:${sm.list().length}`));
      await sm.create("Isolated", { isolation: "worktree" });
      // The re-push must trail the session list: an app learns the checkout
      // exists from that list and only then subscribes to its stream, so a
      // status frame sent any earlier has no subscriber and is never replayed.
      expect(order).toEqual(["prepare", "sessions:1", "announce:checkout-1"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("re-announces when the session is already running", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    const announces: string[] = [];
    const record: CheckoutRecord = {
      id: "checkout-1", projectId: "p", kind: "managed-worktree", path: dir,
      branch: "antgrid/session-1", baseRef: "main", managed: true,
      sessionId: "s", createdAt: 1,
    };
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        ...record, sessionId: args.sessionId,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => record,
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
        agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        prepareCheckoutRuntime: async () => {},
        resolveCheckout: async () => record,
        announceCheckoutRuntime: (id) => { announces.push(id); },
        resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
      });
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id);
      announces.length = 0;

      // The second start finds the PTY already up. It must STILL announce: the
      // caller asked because it has no state for this checkout, and returning
      // silently is what left a reconnected app on "waiting for agent".
      await sm.start(created.id);
      expect(announces).toEqual(["checkout-1"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("re-announces when an already-running CHAT session is started again", async () => {
    // Chat returns before the PTY branch's `tm.has(id)` guard ever runs, so the
    // re-announce needs its own path — and chat is the mode most likely to be
    // resumed after a reconnect, which is the case this whole re-push exists
    // for. Guarding on a `runningChat` snapshot read AFTER the add would fire
    // on the first start and never on a restart; that inversion is invisible
    // to the PTY test above.
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    const announces: string[] = [];
    const chatStarts: string[] = [];
    const record: CheckoutRecord = {
      id: "checkout-1", projectId: "p", kind: "managed-worktree", path: dir,
      branch: "antgrid/session-1", baseRef: "main", managed: true,
      sessionId: "s", createdAt: 1,
    };
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        ...record, sessionId: args.sessionId,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => record,
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
        agentSpec: { command: "codex", name: "codex" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        prepareCheckoutRuntime: async () => {},
        resolveCheckout: async () => record,
        announceCheckoutRuntime: (id) => { announces.push(id); },
        resolveAgentSpec: async () => ({ command: "codex", name: "codex" }),
        onStartChat: (opts) => { chatStarts.push(opts.sessionId); },
      });
      const created = await sm.create("Isolated chat", { isolation: "worktree", mode: "chat" });
      await sm.start(created.id);
      // The FIRST start must not re-announce: createWorktree already did, and
      // the runtime pushes its own state as it comes up.
      announces.length = 0;

      await sm.start(created.id);
      expect(chatStarts).toEqual([created.id, created.id]);
      expect(announces).toEqual(["checkout-1"]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("rolls back the prepared checkout when its working directory is unsafe", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    let rolledBack = false;
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: join(dir, "wt"),
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => { rolledBack = true; },
      recordFor: async () => ({ id: "checkout-1" } as CheckoutRecord),
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
        agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        resolveAgentSpec: async () => ({ command: "claude", name: "claude-code", workingDir: ".." }),
      });
      await expect(sm.create("Isolated", { isolation: "worktree" })).rejects.toMatchObject({ code: "WORKTREE_WORKING_DIR_UNSAFE" });
      expect(rolledBack).toBe(true);
      expect(sm.list()).toHaveLength(0);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("starts a shared and an isolated session with no cwd crossover", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    const worktree = join(dir, "wt");
    // startCheckout stats the checkout path before spawning — a record says
    // nothing about the disk — so this fake worktree has to really exist.
    mkdirSync(worktree, { recursive: true });
    const terminal = fakeTerminal();
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: worktree,
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => ({ id: "checkout-1" } as CheckoutRecord),
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: terminal as any,
        agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        prepareCheckoutRuntime: async () => {},
        teardownCheckoutRuntime: async () => {},
        resolveCheckout: async () => ({
          id: "checkout-1", projectId: "p", kind: "managed-worktree", path: worktree,
          branch: "antgrid/session-1", baseRef: "main", managed: true,
          sessionId: "s", createdAt: 1,
        }),
        resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
      });
      const shared = await sm.create("Shared");
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      await sm.start(shared.id);
      await sm.start(isolated.id);

      const cwdOf = (id: string) =>
        terminal.spawns.find((s) => s.terminalId === id)?.cwd;
      expect(cwdOf(shared.id)).toBe(dir);
      expect(cwdOf(isolated.id)).toBe(worktree);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("classifies only main-bound sessions as main-checkout", async () => {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-session-"));
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: join(dir, "wt"),
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => ({ id: "checkout-1" } as CheckoutRecord),
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => {},
    } as unknown as WorktreeManager;
    try {
      const sm = new SessionManager({
        projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
        agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
        worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
        prepareCheckoutRuntime: async () => {},
        teardownCheckoutRuntime: async () => {},
        resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
      });
      const shared = await sm.create("Shared");
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      expect(sm.isMainCheckoutSession(shared.id)).toBe(true);
      expect(sm.isMainCheckoutSession(isolated.id)).toBe(false);
      // Config `terminals:` slots and the project-wide notification fallback
      // are not sessions at all, and they live in the primary working tree.
      expect(sm.isMainCheckoutSession("dev-server")).toBe(true);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("isolated session checkout state", () => {
  /** One harness for the resume arms: each case swaps only the option that
   *  decides which of them the start takes. */
  function harness(dir: string, opts: {
    resolveCheckout?: () => Promise<CheckoutRecord | undefined>;
    workingDir?: () => string | undefined;
    recordFor?: () => Promise<CheckoutRecord | undefined>;
    onRemove?: () => void;
    onTeardown?: (checkoutId: string) => void;
  }) {
    const worktree = join(dir, "wt");
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: worktree,
        branch: "antgrid/session-1", baseRef: null, managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => {},
      recordFor: opts.recordFor ?? (async () => ({ id: "checkout-1" } as CheckoutRecord)),
      inspect: async () => {
        opts.onRemove?.();
        return { exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false };
      },
      remove: async () => { opts.onRemove?.(); },
    } as unknown as WorktreeManager;
    const sm = new SessionManager({
      projectId: "p", storeDir: dir, projectPath: dir, terminalManager: fakeTerminal() as any,
      agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
      worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
      prepareCheckoutRuntime: async () => {},
      teardownCheckoutRuntime: async (checkoutId: string) => { opts.onTeardown?.(checkoutId); },
      resolveCheckout: opts.resolveCheckout ?? (async () => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: worktree,
        branch: "antgrid/session-1", baseRef: null, managed: true, sessionId: "s", createdAt: 1,
      })),
      resolveAgentSpec: async () => ({ command: "claude", name: "claude-code", workingDir: opts.workingDir?.() }),
    });
    return { sm, worktree };
  }

  async function withDir(fn: (dir: string) => Promise<void>): Promise<void> {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-state-"));
    try { await fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
  }

  it("stamps missing when the checkout record is gone", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, { resolveCheckout: async () => undefined });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      await expect(sm.start(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_MISSING" });
      expect(sm.get(isolated.id)?.checkoutState).toBe("missing");
    });
  });

  it("stamps missing when the checkout directory is gone from disk", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, {});
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      // The record is durable metadata and outlives the directory. Without the
      // stat the session spawns a PTY into a cwd that does not exist while the
      // badge still reads `ready`.
      await expect(sm.start(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_MISSING" });
      expect(sm.get(isolated.id)?.checkoutState).toBe("missing");
    });
  });

  it("stamps failed when antgrid.yaml moved the working dir out of the checkout", async () => {
    await withDir(async (dir) => {
      let workingDir: string | undefined;
      const { sm, worktree } = harness(dir, { workingDir: () => workingDir });
      mkdirSync(worktree, { recursive: true });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      workingDir = "..";
      // `failed` is the repairable half of the split: the checkout is right
      // there, the configuration pointing at it is not.
      await expect(sm.start(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_WORKING_DIR_UNSAFE" });
      expect(sm.get(isolated.id)?.checkoutState).toBe("failed");

      workingDir = undefined;
      await sm.start(isolated.id);
      expect(sm.get(isolated.id)?.checkoutState).toBe("ready");
    });
  });

  it("stamps failed when resolving the checkout throws", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, {
        resolveCheckout: async () => { throw new Error("runtime preparation failed"); },
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      await expect(sm.start(isolated.id)).rejects.toThrow("runtime preparation failed");
      expect(sm.get(isolated.id)?.checkoutState).toBe("failed");
    });
  });

  it("deletes an isolated session whose checkout record no longer exists", async () => {
    await withDir(async (dir) => {
      let reclaimAttempted = false;
      const tornDown: string[] = [];
      const { sm } = harness(dir, {
        recordFor: async () => undefined,
        onRemove: () => { reclaimAttempted = true; },
        onTeardown: (checkoutId) => tornDown.push(checkoutId),
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      expect(await sm.delete(isolated.id)).toBe(true);
      // Nothing left to reclaim, so neither preflight nor removal may run — and
      // the row must go, or reconciliation (and every store the pre-fix forget()
      // destroyed) leaves a session nothing can ever delete.
      expect(reclaimAttempted).toBe(false);
      // The missing metadata says nothing about the runtime built off it: the
      // checkout's `services:` PTYs and watcher outlive the record, and this row
      // is the last thing on the machine that can name their checkoutId.
      expect(tornDown).toEqual(["checkout-1"]);
      expect(sm.list()).toHaveLength(0);
    });
  });
});

describe("isolated session worktree.setup", () => {
  const CHECKOUT_ID = "checkout-1";

  function record(dir: string): CheckoutRecord {
    return {
      id: CHECKOUT_ID, projectId: "p", kind: "managed-worktree", path: join(dir, "wt"),
      branch: "antgrid/session-1", baseRef: "main", managed: true, sessionId: null, createdAt: 1,
    };
  }

  /** A setup runner the test drives by hand. The real one reports from a PTY on
   *  its own schedule; every case here is about what the manager does at a
   *  transition, so the transition has to be the test's to place. */
  function harness(
    dir: string,
    opts: {
      removeCheckout?: () => void;
      declaresSetup?: boolean;
      startAgent?: "afterSetup" | "immediate";
    } = {},
  ) {
    const worktree = join(dir, "wt");
    // startCheckout stats the checkout before spawning — a record says nothing
    // about the disk.
    mkdirSync(worktree, { recursive: true });
    const terminal = fakeTerminal();
    const runs: Array<{
      checkoutId: string;
      sessionId: string;
      report: (progress: CheckoutSetupProgress) => void;
    }> = [];
    const order: string[] = [];
    const cancelled: string[] = [];
    const servicesStarted: string[] = [];
    const deferred: boolean[] = [];
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        ...record(dir), sessionId: args.sessionId,
      }),
      rollbackPrepared: async () => {},
      recordFor: async () => record(dir),
      inspect: async () => ({ exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false }),
      remove: async () => { order.push("remove"); opts.removeCheckout?.(); },
    } as unknown as WorktreeManager;
    const sm = new SessionManager({
      projectId: "p", storeDir: dir, projectPath: dir, terminalManager: terminal as any,
      agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
      worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
      prepareCheckoutRuntime: async (_checkout, prepareOpts) => {
        deferred.push(prepareOpts?.deferServices === true);
      },
      teardownCheckoutRuntime: async () => { order.push("teardown"); },
      startDeferredServices: async (checkoutId) => { servicesStarted.push(checkoutId); },
      runCheckoutSetup: (checkout, sessionId, onProgress) => {
        runs.push({ checkoutId: checkout.id, sessionId, report: onProgress });
      },
      cancelCheckoutSetup: async (checkoutId) => { order.push("cancel-setup"); cancelled.push(checkoutId); },
      checkoutSetupPolicy: () => ({
        declares: opts.declaresSetup ?? true,
        startAgent: opts.startAgent ?? "afterSetup",
      }),
      resolveCheckout: async () => ({ ...record(dir), sessionId: "s" }),
      resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
    });
    return { sm, terminal, runs, order, cancelled, servicesStarted, deferred };
  }

  async function withDir(fn: (dir: string) => Promise<void>): Promise<void> {
    const dir = mkdtempSync(join(tmpdir(), "antgrid-worktree-setup-"));
    try { await fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
  }

  /** The queued start reaches the PTY through an async re-entry into start(). */
  async function waitForTerminal(terminal: ReturnType<typeof fakeTerminal>, id: string): Promise<void> {
    for (let i = 0; i < 200 && !terminal.has(id); i++) {
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    expect(terminal.has(id)).toBe(true);
  }

  /** The marker is written off the settle path, behind the store's own write
   *  lock and a real file write, so its arrival is polled rather than assumed. */
  async function markerSettles(store: CheckoutStore, expected: string): Promise<void> {
    for (let i = 0; i < 200; i++) {
      if ((await store.get(CHECKOUT_ID))?.setupState === expected) return;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
    expect((await store.get(CHECKOUT_ID))?.setupState).toBe(expected as never);
  }

  /** Seed the durable metadata the marker writes land on. Without a row,
   *  stampSetupMarker has nothing to annotate and returns silently. */
  async function seedCheckout(dir: string, extra: Partial<CheckoutRecord> = {}): Promise<void> {
    await new CheckoutStore(dir, "p").put({ ...record(dir), ...extra });
  }

  it("holds the agent behind a running setup and says so on the entry", async () => {
    await withDir(async (dir) => {
      const { sm, terminal, runs, deferred } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      // The services block is held with it: `bun run dev` against a worktree
      // with no node_modules fails before the user has seen the session.
      expect(deferred).toEqual([true]);
      expect(runs).toHaveLength(1);
      expect(created.setup).toMatchObject({ state: "running", stepIndex: 0, pendingStart: false });

      await sm.start(created.id, "fix the flaky test");
      // Queued, not refused — and the entry carries the truth, which is how the
      // app tells "queued" from "started" behind an ok reply.
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(true);
      expect(terminal.has(created.id)).toBe(false);
    });
  });

  it("keeps the step ledger a later report leaves out", async () => {
    await withDir(async (dir) => {
      const { sm, runs } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      const report = runs[0]!.report;

      report({
        state: "running", stepIndex: 0, stepCount: 2, stepName: "Copy env files",
        stepNames: ["Copy env files", "Install dependencies"], terminalId: "t",
      });
      expect(sm.get(created.id)?.setup?.stepNames).toEqual([
        "Copy env files", "Install dependencies",
      ]);

      // A report that omits the ledger must not blank one already on screen —
      // same retention `terminalId` gets, and for the same reason: the app has
      // no second source for either.
      report({ state: "running", stepIndex: 1, stepCount: 2, stepName: "Install dependencies" });
      expect(sm.get(created.id)?.setup?.stepNames).toEqual([
        "Copy env files", "Install dependencies",
      ]);
      expect(sm.get(created.id)?.setup?.terminalId).toBe("t");
    });
  });

  it("an immediate policy launches the agent alongside the run", async () => {
    await withDir(async (dir) => {
      const { sm, terminal, runs, deferred } = harness(dir, { startAgent: "immediate" });
      const created = await sm.create("Isolated", { isolation: "worktree" });
      // The services block is NOT released with the agent: `bun run dev` needs
      // the node_modules the run is still installing, and unlike an agent
      // nobody is reading its output when it fails for that.
      expect(deferred).toEqual([true]);
      expect(runs).toHaveLength(1);

      await sm.start(created.id, "fix the flaky test");
      await waitForTerminal(terminal, created.id);
      // Never queued, so there is nothing for the settle to fire later — the
      // start reply and the entry agree that the agent is up.
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(false);
      // And the run is still the run: the banner keeps reporting a tree the
      // agent is already working in, which is the whole reason it must.
      expect(sm.get(created.id)?.setup?.state).toBe("running");
    });
  });

  it("skip against an already-open gate leaves the agent alone", async () => {
    await withDir(async (dir) => {
      // The app can only send this from a view that may be a frame behind, so
      // a skip aimed at a gate `immediate` already opened must be a no-op —
      // never a second spawn over the agent that is running.
      const { sm, terminal, runs, cancelled } = harness(dir, { startAgent: "immediate" });
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id);
      await waitForTerminal(terminal, created.id);
      const spawns = terminal.spawns.length;

      await sm.applySetupAction(created.id, "skip");
      expect(terminal.spawns.length).toBe(spawns);
      expect(cancelled).toEqual([]);
      expect(sm.get(created.id)?.setup?.state).toBe("running");
      runs[0]!.report({ state: "done", stepIndex: 1, stepCount: 2 });
      expect(sm.get(created.id)?.setup?.state).toBe("done");
    });
  });

  it("skip releases the gate while the run itself keeps going", async () => {
    await withDir(async (dir) => {
      const { sm, terminal, runs, cancelled, servicesStarted } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");

      await sm.applySetupAction(created.id, "skip");
      await waitForTerminal(terminal, created.id);
      // "I know the deps are cached", not "stop": nothing is killed, the banner
      // keeps reporting, and the services stay this run's to release.
      expect(cancelled).toEqual([]);
      expect(servicesStarted).toEqual([]);
      expect(sm.get(created.id)?.setup).toMatchObject({ state: "running", pendingStart: false });

      runs[0]!.report({ state: "done", stepIndex: 1, stepCount: 2, terminalId: `${CHECKOUT_ID}:setup` });
      expect(sm.get(created.id)?.setup?.state).toBe("done");
    });
  });

  it("a start issued after skip is not queued again", async () => {
    await withDir(async (dir) => {
      const { sm, terminal } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.applySetupAction(created.id, "skip");
      await sm.start(created.id);
      await waitForTerminal(terminal, created.id);
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(false);
    });
  });

  it("cancel kills the run, marks it skipped and fires the queued start", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const { sm, terminal, cancelled, servicesStarted } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");

      await sm.applySetupAction(created.id, "cancel");
      expect(cancelled).toEqual([CHECKOUT_ID]);
      // Skipped, not failed: the user ended this run and a red banner would be
      // reporting their own choice back at them.
      expect(sm.get(created.id)?.setup).toMatchObject({ state: "skipped", pendingStart: false });
      expect(sm.get(created.id)?.setup?.exitCode).toBeUndefined();
      await waitForTerminal(terminal, created.id);
      expect(servicesStarted).toEqual([CHECKOUT_ID]);
      await markerSettles(new CheckoutStore(dir, "p"), "skipped");
    });
  });

  it("a failed run still releases the services and the queued agent", async () => {
    await withDir(async (dir) => {
      // onFailure is `warn`: a half-provisioned tree gets its session anyway,
      // with a persistent banner rather than a refusal.
      await seedCheckout(dir);
      const { sm, terminal, runs, servicesStarted } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");

      runs[0]!.report({
        state: "failed", stepIndex: 1, stepCount: 2, stepName: "Install dependencies",
        exitCode: 1, message: "Install dependencies failed (exit 1)",
      });
      await waitForTerminal(terminal, created.id);
      expect(servicesStarted).toEqual([CHECKOUT_ID]);
      expect(sm.get(created.id)?.setup).toMatchObject({
        state: "failed", exitCode: 1, message: "Install dependencies failed (exit 1)", pendingStart: false,
      });
      const store = new CheckoutStore(dir, "p");
      await markerSettles(store, "failed");
      expect(await store.get(CHECKOUT_ID)).toMatchObject({ setupState: "failed", setupExitCode: 1 });
    });
  });

  it("the dying report of a cancelled run cannot reopen the state the user was shown", async () => {
    await withDir(async (dir) => {
      const { sm, runs } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.applySetupAction(created.id, "cancel");
      // The killed child reports `failed` on its way out; the user asked for the
      // kill, so that report is not the answer they get.
      runs[0]!.report({ state: "failed", stepIndex: 0, stepCount: 2, message: "Setup timed out after 600s" });
      expect(sm.get(created.id)?.setup).toMatchObject({ state: "skipped", message: undefined });
    });
  });

  it("reruns from every terminal state and refuses only while one is live", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const { sm, runs } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      const store = new CheckoutStore(dir, "p");

      // A rerun while the previous attempt is still alive would leave two
      // runners fighting over the same checkout.
      await expect(sm.applySetupAction(created.id, "rerun")).rejects.toThrow(/already running/);

      const terminals: Array<CheckoutSetupProgress> = [
        { state: "done", stepIndex: 1, stepCount: 2 },
        { state: "failed", stepIndex: 0, stepCount: 2, exitCode: 2 },
        { state: "skipped", stepIndex: 0, stepCount: 2 },
      ];
      for (const [index, outcome] of terminals.entries()) {
        runs.at(-1)!.report(outcome);
        expect(sm.get(created.id)?.setup?.state).toBe(outcome.state);
        // Waited for, not assumed: the clear below only means anything once the
        // outcome it replaces has actually reached the file.
        await markerSettles(store, outcome.state);
        await sm.applySetupAction(created.id, "rerun");
        expect(runs).toHaveLength(index + 2);
        expect(sm.get(created.id)?.setup).toMatchObject({ state: "running", stepIndex: 0, stepCount: 0 });
        // Cleared BEFORE the run, never overwritten after it: a bridge that dies
        // mid-rerun must come back `interrupted`, and the previous outcome would
        // claim otherwise.
        expect((await store.get(CHECKOUT_ID))?.setupState).toBeUndefined();
      }
    });
  });

  it("a rerun gates afresh and honours the start queued behind it", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const { sm, terminal, runs } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      runs[0]!.report({ state: "failed", stepIndex: 0, stepCount: 1, exitCode: 1 });
      await sm.applySetupAction(created.id, "rerun");

      // The release the user gave the first run said nothing about this one.
      await sm.start(created.id, "fix the flaky test");
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(true);
      expect(terminal.has(created.id)).toBe(false);

      // Re-run-setup then restart-agent must not make the user retype it.
      runs[1]!.report({ state: "done", stepIndex: 0, stepCount: 1 });
      await waitForTerminal(terminal, created.id);
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(false);
    });
  });

  it("a rerun re-reads a policy that changed since create", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      // The config lives on the checkout's own branch and a rerun is exactly
      // when it has been edited since — answering from the create-time reading
      // would gate a run the user has just told not to.
      const opts: { startAgent?: "afterSetup" | "immediate" } = { startAgent: "afterSetup" };
      const { sm, terminal, runs } = harness(dir, opts);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(true);

      runs[0]!.report({ state: "failed", stepIndex: 0, stepCount: 1, exitCode: 1 });
      // That failure fires the queued start (onFailure is `warn`), so stop the
      // agent again — a rerun re-arms the prompt only for a session that is not
      // already running, and this test is about the gate, not the prompt.
      sm.stop(created.id);
      opts.startAgent = "immediate";
      await sm.applySetupAction(created.id, "rerun");

      await sm.start(created.id, "fix the flaky test");
      await waitForTerminal(terminal, created.id);
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(false);
      expect(sm.get(created.id)?.setup?.state).toBe("running");
    });
  });

  it("carries the prompt a failed run already spent into the rerun", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const { sm, terminal, runs } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");

      // onFailure is `warn`, so the queued start fires into the half-provisioned
      // tree and the prompt is spent on a build the agent cannot run.
      runs[0]!.report({ state: "failed", stepIndex: 0, stepCount: 1, exitCode: 1 });
      await waitForTerminal(terminal, created.id);
      sm.stop(created.id);

      await sm.applySetupAction(created.id, "rerun");
      // Re-armed without the app sending start again: the user fixed the setup,
      // not the prompt.
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(true);

      runs[1]!.report({ state: "done", stepIndex: 1, stepCount: 1 });
      await waitForTerminal(terminal, created.id);
      expect(terminal.spawns.at(-1)?.args?.join(" ")).toContain("fix the flaky test");
    });
  });

  it("does not re-arm a rerun behind an agent that is already running", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const { sm, terminal, runs } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");
      runs[0]!.report({ state: "failed", stepIndex: 0, stepCount: 1, exitCode: 1 });
      await waitForTerminal(terminal, created.id);

      // The live agent already received this prompt; re-arming would deliver it
      // a second time the moment the rerun finished.
      await sm.applySetupAction(created.id, "rerun");
      expect(sm.get(created.id)?.setup?.pendingStart).toBe(false);
    });
  });

  it("refuses a rerun for a session that has no managed workspace", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir);
      const shared = await sm.create("Shared");
      await expect(sm.applySetupAction(shared.id, "rerun")).rejects.toThrow(/no managed workspace/);
      await expect(sm.applySetupAction("nope", "skip")).rejects.toThrow(/session not found/);
    });
  });

  it("skip and cancel land as no-ops once the run is over", async () => {
    await withDir(async (dir) => {
      // The app can only send these from a view that may be a frame behind the
      // state it is acting on; a cancel that lands late asked for what it has.
      await seedCheckout(dir);
      const { sm, runs, cancelled } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      runs[0]!.report({ state: "done", stepIndex: 1, stepCount: 2 });
      await sm.applySetupAction(created.id, "skip");
      await sm.applySetupAction(created.id, "cancel");
      expect(cancelled).toEqual([]);
      expect(sm.get(created.id)?.setup?.state).toBe("done");
    });
  });

  it("reports interrupted after a restart and never reruns on its own", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const first = harness(dir);
      const created = await first.sm.create("Isolated", { isolation: "worktree" });
      // No marker was ever stamped: this bridge died mid-run.

      const second = harness(dir);
      await new Promise((resolve) => setTimeout(resolve, 20));
      expect(second.sm.get(created.id)?.setup).toMatchObject({
        state: "interrupted", stepIndex: 0, stepCount: 0,
      });
      // A setup step can be expensive or destructive and the user did not ask
      // for one on this launch.
      expect(second.runs).toEqual([]);
      expect(second.terminal.has(created.id)).toBe(false);
      // No transcript either — it died with the PTY that wrote it, so the app
      // must not be offered a log it cannot replay.
      expect(second.sm.get(created.id)?.setup?.terminalId).toBeUndefined();
      // ...and the gate is open: a recovered state has no runner to wait for.
      await second.sm.start(created.id);
      await waitForTerminal(second.terminal, created.id);
    });
  });

  it("reports nothing for a checkout that never had a block to run", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const first = harness(dir);
      const created = await first.sm.create("Isolated", { isolation: "worktree" });

      // A marker's absence alone does not mean a run died: every checkout cut
      // before the project declared a setup block carries none either, and
      // reporting those as interrupted banners every isolated session an
      // upgrade inherits.
      const second = harness(dir, { declaresSetup: false });
      await new Promise((resolve) => setTimeout(resolve, 20));
      expect(second.sm.get(created.id)?.setup).toBeUndefined();
    });
  });

  it("recovers the durable outcome of a run that did finish", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir, { setupState: "failed", setupFinishedAt: 42, setupExitCode: 7 });
      const first = harness(dir);
      const created = await first.sm.create("Isolated", { isolation: "worktree" });
      first.runs[0]!.report({ state: "failed", stepIndex: 0, stepCount: 1, exitCode: 7 });

      const second = harness(dir);
      await new Promise((resolve) => setTimeout(resolve, 20));
      expect(second.sm.get(created.id)?.setup).toMatchObject({
        state: "failed", exitCode: 7, finishedAt: 42,
      });
    });
  });

  it("deleting a session cancels its live setup instead of refusing", async () => {
    await withDir(async (dir) => {
      await seedCheckout(dir);
      const { sm, order, cancelled } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      expect(await sm.delete(created.id)).toBe(true);
      expect(cancelled).toEqual([CHECKOUT_ID]);
      // Before the teardown and the removal, not after: a live `bun install`
      // holding the checkout as its cwd is what makes `git worktree remove` fail
      // on Windows. A user deleting a session does not want to be told to wait
      // it out.
      expect(order).toEqual(["cancel-setup", "teardown", "remove"]);
      expect(sm.list()).toHaveLength(0);
    });
  });

  it("a delete's cancel writes no durable marker and starts no services", async () => {
    await withDir(async (dir) => {
      // The checkout is being reclaimed: there is no runtime left to serve the
      // services and no row left for a marker to describe.
      await seedCheckout(dir);
      const { sm, servicesStarted } = harness(dir);
      const created = await sm.create("Isolated", { isolation: "worktree" });
      await sm.start(created.id, "fix the flaky test");
      await sm.delete(created.id);
      expect(servicesStarted).toEqual([]);
      expect((await new CheckoutStore(dir, "p").get(CHECKOUT_ID))?.setupState).toBeUndefined();
    });
  });
});
