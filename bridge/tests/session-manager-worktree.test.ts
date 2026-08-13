import { describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import type { CheckoutRecord } from "../src/worktrees/checkout-types";
import type { WorktreeManager } from "../src/worktrees/worktree-manager";

function fakeTerminal() {
  const running = new Set<string>();
  const spawns: Array<{ terminalId: string; cwd?: string }> = [];
  return {
    spawn: (opts: { terminalId: string; cwd?: string }) => {
      running.add(opts.terminalId);
      spawns.push({ terminalId: opts.terminalId, cwd: opts.cwd });
      return opts.terminalId;
    },
    kill: (id: string) => running.delete(id),
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
