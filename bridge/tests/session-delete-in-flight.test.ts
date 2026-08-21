import { describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "../src/session-manager";
import type { SessionEntry } from "../src/protocol";
import type { CheckoutRecord } from "../src/worktrees/checkout-types";
import type { WorktreeInspection, WorktreeManager } from "../src/worktrees/worktree-manager";

const CHECKOUT_ID = "checkout-1";

function fakeTerminal(alwaysRunning = false) {
  const running = new Set<string>();
  return {
    spawn: (opts: { terminalId: string }) => { running.add(opts.terminalId); return opts.terminalId; },
    // A no-op kill is how a wedged PTY is modelled: `stopAndAwait` keeps waiting
    // on an exit that never comes and times out.
    kill: (id: string) => { if (!alwaysRunning) running.delete(id); },
    treeKilled: () => Promise.resolve(),
    has: (id: string) => alwaysRunning || running.has(id),
  };
}

/** A promise the test resolves by hand, so a delete can be held open across the
 *  exact window the `deleting` flag is supposed to cover. */
function deferred<T>(): { promise: Promise<T>; resolve: (v: T) => void; reject: (e: unknown) => void } {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

interface HarnessOpts {
  inspect?: Partial<WorktreeInspection>;
  recordFor?: () => Promise<CheckoutRecord | undefined>;
  remove?: () => Promise<void>;
  teardownCheckoutRuntime?: (checkoutId: string) => Promise<void>;
  resolveCheckout?: () => Promise<CheckoutRecord | undefined>;
  onPrepare?: () => void;
  terminalManager?: ReturnType<typeof fakeTerminal>;
  teardownTimeoutMs?: number;
}

function harness(dir: string, opts: HarnessOpts = {}) {
  const record: CheckoutRecord = {
    id: CHECKOUT_ID, projectId: "p", kind: "managed-worktree", path: join(dir, "wt"),
    branch: "antgrid/session-1", baseRef: "main", managed: true, sessionId: "s", createdAt: 1,
  };
  const manager = {
    prepareForSession: async (args: { sessionId: string }): Promise<CheckoutRecord> => ({
      ...record, sessionId: args.sessionId,
    }),
    rollbackPrepared: async () => {},
    recordFor: opts.recordFor ?? (async () => record),
    inspect: async (): Promise<WorktreeInspection> => ({
      exists: true, registered: true, dirty: false, unpushedCommits: false, locked: false,
      ...opts.inspect,
    }),
    remove: opts.remove ?? (async () => {}),
  } as unknown as WorktreeManager;
  const sm = new SessionManager({
    projectId: "p", storeDir: dir, projectPath: dir,
    terminalManager: (opts.terminalManager ?? fakeTerminal()) as any,
    agentSpec: { command: "claude", name: "claude-code" }, sendMessage: () => {},
    worktreeSessionsSupported: true, isGitRepository: async () => true, worktreeManager: manager,
    teardownTimeoutMs: opts.teardownTimeoutMs,
    prepareCheckoutRuntime: async () => { opts.onPrepare?.(); },
    teardownCheckoutRuntime: opts.teardownCheckoutRuntime ?? (async () => {}),
    resolveCheckout: opts.resolveCheckout ?? (async () => record),
    resolveAgentSpec: async () => ({ command: "claude", name: "claude-code" }),
  });
  return { sm, record };
}

async function withDir(fn: (dir: string) => Promise<void>): Promise<void> {
  const dir = mkdtempSync(join(tmpdir(), "antgrid-delete-flag-"));
  try { await fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}

/** Every session list the manager emitted, snapshotted at emit time — the flag
 *  is transient, so reading it after the fact answers a different question. */
function recordEmits(sm: SessionManager): SessionEntry[][] {
  const emits: SessionEntry[][] = [];
  sm.onChange(() => emits.push(sm.list()));
  return emits;
}

function sessionsFilePath(dir: string): string {
  return join(dir, "agents", "p", "sessions.json");
}

describe("delete-in-flight flag", () => {
  it("a dirty preflight refusal never flags the session", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, { inspect: { dirty: true } });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const emits = recordEmits(sm);

      await expect(sm.delete(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_DIRTY" });
      // The confirm ladder's guarantee: a refusal the user can still answer
      // destroys nothing and must not have moved the row at all.
      expect(emits).toEqual([]);
      expect(sm.list()[0]?.deleting).toBe(false);
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
    });
  });

  it("an unpushed-commits refusal never flags the session", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, { inspect: { unpushedCommits: true } });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const emits = recordEmits(sm);

      await expect(sm.delete(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_UNPUSHED" });
      expect(emits).toEqual([]);
      expect(sm.list()[0]?.deleting).toBe(false);
    });
  });

  it("an in-flight delete is advertised without touching sessions.json", async () => {
    await withDir(async (dir) => {
      const gate = deferred<void>();
      const { sm } = harness(dir, { remove: () => gate.promise });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const before = readFileSync(sessionsFilePath(dir), "utf8");
      const emits = recordEmits(sm);

      const deletion = sm.delete(isolated.id) as Promise<boolean>;
      // The whole point of the flag: an app learns the delete started long
      // before the row disappears at the end of it.
      await Bun.sleep(0);
      expect(emits[0]?.[0]).toMatchObject({ id: isolated.id, deleting: true });
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(true);

      const during = readFileSync(sessionsFilePath(dir), "utf8");
      expect(during).toBe(before);
      // Asserted on the file text, not on a re-read through the schema: a
      // persisted `deleting` would come back from a crash as a row that is
      // permanently pending and permanently undeletable.
      expect(during).not.toContain("deleting");

      gate.resolve();
      expect(await deletion).toBe(true);
      expect(sm.list()).toHaveLength(0);
    });
  });

  it("clears the flag before the rollback re-prepares the runtime", async () => {
    await withDir(async (dir) => {
      const observed: boolean[] = [];
      const { sm } = harness(dir, {
        remove: async () => { throw new Error("git refused"); },
        onPrepare: () => observed.push(sm.isCheckoutDeleting(CHECKOUT_ID)),
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      await expect(sm.delete(isolated.id)).rejects.toThrow("git refused");
      // Two prepares: the create's, and the rollback's. The rollback is
      // restoring the checkout, so the guard must already be open for it —
      // clearing in a `finally` after the rebuild would refuse everything the
      // restored runtime serves.
      expect(observed).toEqual([false, false]);
    });
  });

  it("a refused removal leaves the row un-flagged and re-emitted", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, { remove: async () => { throw new Error("git refused"); } });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const emits = recordEmits(sm);

      await expect(sm.delete(isolated.id)).rejects.toThrow("git refused");
      expect(emits.at(-1)?.[0]).toMatchObject({ id: isolated.id, deleting: false });
      expect(sm.list()).toHaveLength(1);
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
    });
  });

  it("completes on an exit delivered through noteExited, as production delivers it", async () => {
    await withDir(async (dir) => {
      // The other fakes here drop the id inside `kill()`, which takes
      // `awaitTerminalExit`'s no-live-PTY fast path and never registers a
      // waiter. Production's TerminalManager keeps the id until the async
      // `terminal:exited` handler runs, so the delete genuinely depends on
      // `noteExited` landing — the one path the rest of this file cannot reach.
      const { sm } = harness(dir, {
        terminalManager: fakeTerminal(true),
        teardownTimeoutMs: 500,
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      const deletion = sm.delete(isolated.id) as Promise<boolean>;
      await Bun.sleep(0);
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(true);

      sm.noteExited(isolated.id);
      expect(await deletion).toBe(true);
      expect(sm.list()).toHaveLength(0);
    });
  });

  it("waits for the killed session's process tree, not only its exit", async () => {
    await withDir(async (dir) => {
      const tree = deferred<void>();
      const tm = fakeTerminal();
      tm.treeKilled = () => tree.promise;
      const order: string[] = [];
      const { sm } = harness(dir, {
        terminalManager: tm,
        teardownCheckoutRuntime: async () => { order.push("teardown"); },
        remove: async () => { order.push("remove"); },
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      const deletion = sm.delete(isolated.id) as Promise<boolean>;
      await Bun.sleep(0);
      // The PTY has reported its exit and taskkill is still walking the rest of
      // the tree. Sweeping the directory here is the sharing violation that
      // strands the session undeletable, so nothing may have run yet.
      expect(order).toEqual([]);

      tree.resolve();
      expect(await deletion).toBe(true);
      expect(order).toEqual(["teardown", "remove"]);
    });
  });

  it("a session that will not stop clears the flag", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, {
        terminalManager: fakeTerminal(true),
        teardownTimeoutMs: 10,
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const emits = recordEmits(sm);

      await expect(sm.delete(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_DELETE_FAILED" });
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
      expect(emits.at(-1)?.[0]).toMatchObject({ deleting: false });
      expect(sm.list()).toHaveLength(1);
    });
  });

  it("a throwing teardownCheckoutRuntime clears the flag", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir, {
        teardownCheckoutRuntime: async () => { throw new Error("teardown exploded"); },
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      // Propagates unchanged, and the flag is still gone — which is what proves
      // the outer catch exists rather than only the inner one around `remove`.
      await expect(sm.delete(isolated.id)).rejects.toThrow("teardown exploded");
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
      expect(sm.list()).toHaveLength(1);
    });
  });

  it("a successful delete leaves no flag behind", async () => {
    await withDir(async (dir) => {
      const { sm } = harness(dir);
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const emits = recordEmits(sm);

      expect(await sm.delete(isolated.id)).toBe(true);
      expect(sm.list()).toHaveLength(0);
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
      // One emit announces the delete, one announces the row's removal — the
      // happy path adds no third emit of its own.
      expect(emits).toHaveLength(2);
      expect(emits[0]?.[0]).toMatchObject({ deleting: true });
      expect(emits[1]).toEqual([]);
    });
  });

  it("the metadata-less branch flags around its teardown", async () => {
    await withDir(async (dir) => {
      const observed: boolean[] = [];
      const { sm } = harness(dir, {
        recordFor: async () => undefined,
        teardownCheckoutRuntime: async () => { observed.push(sm.isCheckoutDeleting(CHECKOUT_ID)); },
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      expect(await sm.delete(isolated.id)).toBe(true);
      // Every teardown that happens inside a delete is flagged, including this
      // one — the row is gone milliseconds later, but the invariant is simpler
      // than an exception for a branch that is usually fast.
      expect(observed).toEqual([true]);
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
      expect(sm.list()).toHaveLength(0);
    });
  });

  it("a second delete while one is in flight is refused", async () => {
    await withDir(async (dir) => {
      const gate = deferred<void>();
      const { sm } = harness(dir, { remove: () => gate.promise });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });

      const first = sm.delete(isolated.id) as Promise<boolean>;
      await Bun.sleep(0);
      await expect(sm.delete(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_DELETE_IN_PROGRESS" });
      // The refusal must not clear the flag the first delete is still relying on.
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(true);

      gate.resolve();
      expect(await first).toBe(true);
      expect(sm.isCheckoutDeleting(CHECKOUT_ID)).toBe(false);
    });
  });

  it("start() refuses a session whose delete is in flight", async () => {
    await withDir(async (dir) => {
      const gate = deferred<void>();
      let prepares = 0;
      const { sm } = harness(dir, {
        remove: () => gate.promise,
        onPrepare: () => { prepares += 1; },
      });
      const isolated = await sm.create("Isolated", { isolation: "worktree" });
      const preparesAfterCreate = prepares;

      const deletion = sm.delete(isolated.id) as Promise<boolean>;
      await Bun.sleep(0);
      await expect(sm.start(isolated.id)).rejects.toMatchObject({ code: "WORKTREE_DELETE_IN_PROGRESS" });
      // The other door into a dying checkout's runtime: a start would rebuild it
      // and spawn a PTY inside the directory the delete is about to remove.
      expect(prepares).toBe(preparesAfterCreate);

      gate.resolve();
      expect(await deletion).toBe(true);
    });
  });
});
