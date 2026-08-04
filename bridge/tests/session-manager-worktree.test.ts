import { describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
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
    const terminal = fakeTerminal();
    const manager = {
      prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
        id: "checkout-1", projectId: "p", kind: "managed-worktree", path: worktree,
        branch: "antgrid/session-1", baseRef: "main", managed: true,
        sessionId: args.sessionId, createdAt: 1,
      }),
      rollbackPrepared: async () => {},
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
