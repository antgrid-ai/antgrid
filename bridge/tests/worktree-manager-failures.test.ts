// The delete guards that need Git to fail or lie. `worktree-manager.test.ts`
// drives real repositories, which is right for assertions about Git's actual
// semantics but cannot reach a non-zero `worktree remove` or a listing that
// still reports a worktree Git just removed. Those branches decide whether a
// failed delete strands a checkout the UI can no longer see, so each case here
// also asserts the CheckoutStore row survives.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import type { CheckoutRecord } from "../src/worktrees/checkout-types";
import type { GitCommandResult, GitRunner } from "../src/worktrees/project-resolver";
import { WorktreeManager } from "../src/worktrees/worktree-manager";

const BRANCH = "antgrid/session-abcdefgh";
const HEAD = "0".repeat(40);

interface FakeGitOptions {
  registered?: boolean;
  dirty?: boolean;
  unpushed?: boolean;
  removeExitCode?: number;
  /** Whether a zero-exit `worktree remove` also stops Git reporting the worktree. */
  removeDeregisters?: boolean;
  branchDeleteExitCode?: number;
}

/** Answers exactly the invocations `inspect` and `removeNow` make, and throws on
 * anything else so a new Git call cannot silently take a canned reply. */
function fakeGit(worktreePath: string, options: FakeGitOptions = {}) {
  const state = {
    registered: options.registered ?? true,
    removeDeregisters: options.removeDeregisters ?? true,
  };
  const calls: string[][] = [];
  const ok = (stdout = ""): GitCommandResult => ({ exitCode: 0, stdout, stderr: "" });
  const fail = (exitCode: number): GitCommandResult => ({ exitCode, stdout: "", stderr: "fake git failure" });

  const run: GitRunner = async (args) => {
    calls.push(args);
    switch (args.slice(0, 2).join(" ")) {
      case "worktree list":
        if (!state.registered) return ok("");
        return ok([`worktree ${worktreePath}`, `HEAD ${HEAD}`, `branch refs/heads/${BRANCH}`, ""].join("\0"));
      case "worktree remove": {
        const exitCode = options.removeExitCode ?? 0;
        if (exitCode !== 0) return fail(exitCode);
        if (state.removeDeregisters) state.registered = false;
        return ok();
      }
      case "branch -D":
        return (options.branchDeleteExitCode ?? 0) === 0 ? ok() : fail(options.branchDeleteExitCode!);
    }
    if (args[0] === "status") return ok(options.dirty ? " M readme.txt\n" : "");
    if (args[0] === "rev-list") return ok(options.unpushed ? `${HEAD}\n` : "");
    throw new Error(`unexpected git invocation: ${args.join(" ")}`);
  };
  return { run, calls };
}

describe("WorktreeManager delete failures", () => {
  let abDir: string;
  let repoPath: string;
  let worktreePath: string;
  const projectId = "project-failures";

  beforeEach(() => {
    abDir = mkdtempSync(join(tmpdir(), "antgrid-worktree-fail-home-"));
    repoPath = mkdtempSync(join(tmpdir(), "antgrid-worktree-fail-repo-"));
    // `inspect` stats the recorded path directly, so the directory has to be
    // real even though nothing here is a Git repository.
    worktreePath = mkdtempSync(join(tmpdir(), "antgrid-worktree-fail-wt-"));
  });
  afterEach(() => {
    for (const dir of [abDir, repoPath, worktreePath]) rmSync(dir, { recursive: true, force: true });
  });

  function store(): CheckoutStore {
    return new CheckoutStore(abDir, projectId);
  }

  async function seed(overrides: Partial<CheckoutRecord> = {}): Promise<CheckoutRecord> {
    const record: CheckoutRecord = {
      id: "checkout-1", projectId, kind: "managed-worktree", path: worktreePath,
      branch: BRANCH, baseRef: null, managed: true, sessionId: "session-1", createdAt: 1,
      ...overrides,
    };
    await store().put(record);
    return record;
  }

  function manager(git: GitRunner): WorktreeManager {
    return new WorktreeManager({
      abDir,
      git,
      // Nothing called prepareForSession here, so the repository path can only
      // come from the catalogue resolver — the same route a restart takes.
      resolveRepoPath: async (id) => (id === projectId ? repoPath : undefined),
    });
  }

  test("refuses a checkout Antgrid does not own, without asking Git anything", async () => {
    for (const overrides of [{ id: "external", kind: "external-worktree" as const }, { id: "unmanaged", managed: false }]) {
      const record = await seed(overrides);
      const git = fakeGit(worktreePath);
      await expect(manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: true }))
        .rejects.toMatchObject({ code: "WORKTREE_CONFLICT" });
      expect(git.calls).toEqual([]);
      expect(await store().get(record.id)).toMatchObject({ id: record.id });
    }
  });

  test("keeps the checkout row when `git worktree remove` fails", async () => {
    const record = await seed();
    const git = fakeGit(worktreePath, { removeExitCode: 1 });
    await expect(manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_DELETE_FAILED" });
    expect(await store().get(record.id)).toMatchObject({ id: record.id });
  });

  test("refuses to remove a directory Git no longer registers", async () => {
    // Git owns worktree removal; deleting an unregistered directory ourselves
    // would leave the repository's administrative files behind.
    const record = await seed();
    const git = fakeGit(worktreePath, { registered: false });
    await expect(manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_DELETE_FAILED" });
    expect(git.calls.some((args) => args[1] === "remove")).toBe(false);
    expect(await store().get(record.id)).toMatchObject({ id: record.id });
  });

  test("keeps the checkout row when Git still reports the worktree after removal", async () => {
    const record = await seed();
    const git = fakeGit(worktreePath, { removeDeregisters: false });
    await expect(manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_DELETE_FAILED" });
    expect(await store().get(record.id)).toMatchObject({ id: record.id });
  });

  test("keeps the checkout row when the requested branch deletion fails", async () => {
    const record = await seed();
    const git = fakeGit(worktreePath, { branchDeleteExitCode: 1 });
    await expect(manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: true }))
      .rejects.toMatchObject({ code: "WORKTREE_DELETE_FAILED" });
    expect(await store().get(record.id)).toMatchObject({ id: record.id });
  });
});
