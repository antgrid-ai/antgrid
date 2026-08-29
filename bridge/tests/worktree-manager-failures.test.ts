// The delete guards that need Git to fail or lie. `worktree-manager.test.ts`
// drives real repositories, which is right for assertions about Git's actual
// semantics but cannot reach a non-zero `worktree remove` or a listing that
// still reports a worktree Git just removed. Those branches decide whether a
// failed delete strands a checkout the UI can no longer see, so each case here
// also asserts what became of the CheckoutStore row — surviving before the
// worktree is gone, and never surviving after it.
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";
import { __setRootForTest } from "../src/logger";
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
  statusExitCode?: number;
  /** Whether a zero-exit `worktree remove` also stops Git reporting the worktree. */
  removeDeregisters?: boolean;
  branchDeleteExitCode?: number;
  /** A rev-list that fails rather than answering, and whether the branch it was
   *  asked about still exists — the two together are what `inspect` reads. */
  revListExitCode?: number;
  branchExists?: boolean;
  /** Whether the repository itself still reads. A `show-ref` that finds nothing
   *  means "branch gone" only here — in an unreadable repository it means
   *  nothing at all. */
  repoReadable?: boolean;
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
        // A successful removal takes the working tree with it. The fake has to
        // do that too: `removeNow` now re-tests the directory afterwards, so a
        // fake that reported success and left it standing would read as Git
        // half-finishing the job.
        rmSync(worktreePath, { recursive: true, force: true });
        if (state.removeDeregisters) state.registered = false;
        return ok();
      }
      case "worktree prune":
        // Faithful to Git: an entry is prunable once nothing claims it, which
        // is exactly what deleting the directory ourselves achieves.
        if (!existsSync(worktreePath)) state.registered = false;
        return ok();
      case "branch -D":
        return (options.branchDeleteExitCode ?? 0) === 0 ? ok() : fail(options.branchDeleteExitCode!);
    }
    if (args[0] === "status") {
      const exitCode = options.statusExitCode ?? 0;
      if (exitCode !== 0) return fail(exitCode);
      return ok(options.dirty ? " M readme.txt\n" : "");
    }
    if (args[0] === "rev-list") {
      const exitCode = options.revListExitCode ?? 0;
      return exitCode === 0 ? ok(options.unpushed ? `${HEAD}\n` : "") : fail(exitCode);
    }
    if (args[0] === "show-ref") return (options.branchExists ?? true) ? ok() : fail(1);
    if (args[0] === "rev-parse") return (options.repoReadable ?? true) ? ok(".git") : fail(128);
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

  function manager(git: GitRunner, extra: ConstructorParameters<typeof WorktreeManager>[0] = {}): WorktreeManager {
    return new WorktreeManager({
      abDir,
      git,
      // Nothing called prepareForSession here, so the repository path can only
      // come from the catalogue resolver — the same route a restart takes.
      resolveRepoPath: async (id) => (id === projectId ? repoPath : undefined),
      ...extra,
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

  test("keeps the checkout row when a directory it cannot reclaim survives `git worktree remove`", async () => {
    const record = await seed();
    const git = fakeGit(worktreePath, { removeExitCode: 1 });
    await expect(manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_DELETE_FAILED" });
    expect(await store().get(record.id)).toMatchObject({ id: record.id });
  });

  describe("naming what holds a directory that will not go away", () => {
    // The enumeration reads the real machine's process table, so it is injected
    // here for the same reason `git` is: neither a holder nor its absence can
    // be arranged, and the message built out of one is what the user reads.
    test("names the holders in the message and counts them in the event", async () => {
      // "Permission denied" is all the field ever saw. The holder is routinely
      // an orphaned `bun test` the PTY teardown could not reach, and nothing
      // else on the machine will ever name it. The code differs from the
      // holderless case on purpose: the app REPLACES WORKTREE_DELETE_FAILED
      // with a sentence of its own, which would eat the clause below.
      const record = await seed();
      const git = fakeGit(worktreePath, { removeExitCode: 1 });
      const holders = [
        { pid: 18688, name: "bun.exe", cwd: join(worktreePath, "bridge") },
        { pid: 4020, name: "dart.exe", cwd: worktreePath },
      ];
      const lines: string[] = [];
      __setRootForTest({ write: (message: string) => { lines.push(message); } }, "info");
      try {
        await expect(
          manager(git.run, { listHolders: () => holders })
            .remove({ checkoutId: record.id, force: true, deleteBranch: false }),
        ).rejects.toMatchObject({
          code: "WORKTREE_DELETE_HELD",
          message: expect.stringMatching(/Held by bun\.exe \(pid 18688\) in bridge, dart\.exe \(pid 4020\)\.$/),
        });
      } finally {
        __setRootForTest(process.stdout, "info");
      }
      // The count is the whole analytics-safe part: a holder's current
      // directory names the user's home layout, so it stays in the local log.
      expect(lines.join("")).toContain("\"holders\":2");
      expect(lines.join("")).toContain("bun.exe");
    });

    test("names only the first few holders and says how many it left out", async () => {
      const record = await seed();
      const git = fakeGit(worktreePath, { removeExitCode: 1 });
      const holders = Array.from({ length: 5 }, (_, index) => ({
        pid: 100 + index, name: `bun-${index}.exe`, cwd: worktreePath,
      }));
      await expect(
        manager(git.run, { listHolders: () => holders })
          .remove({ checkoutId: record.id, force: true, deleteBranch: false }),
      ).rejects.toThrow(/bun-2\.exe \(pid 102\), and 2 more\.$/);
    });

    test("leaves the message alone when nothing can be named, and still logs the directory", async () => {
      // Off Windows the enumeration answers nothing at all — and on it, a
      // directory can be refused with no live holder to blame. The sentence has
      // to read as it always did, with no dangling "held by".
      const record = await seed();
      const git = fakeGit(worktreePath, { removeExitCode: 1 });
      const lines: string[] = [];
      __setRootForTest({ write: (message: string) => { lines.push(message); } }, "warn");
      try {
        await expect(
          manager(git.run, { listHolders: () => [] })
            .remove({ checkoutId: record.id, force: true, deleteBranch: false }),
        ).rejects.toMatchObject({
          code: "WORKTREE_DELETE_FAILED",
          message: "The isolated worktree's directory could not be removed.",
        });
      } finally {
        __setRootForTest(process.stdout, "info");
      }
      // The event carries a projectId and a count, and this is the one line
      // that ever names WHICH directory survived — without it a support bundle
      // cannot tell one stranded checkout from five identical events.
      expect(lines.join("")).toContain(JSON.stringify(worktreePath).slice(1, -1));
    });

    test("an enumeration that throws cannot change what the delete failed with", async () => {
      // It runs only where a delete has already failed, so the one thing it
      // must never do is replace that failure with its own.
      const record = await seed();
      const git = fakeGit(worktreePath, { removeExitCode: 1 });
      await expect(
        manager(git.run, { listHolders: () => { throw new Error("no process table"); } })
          .remove({ checkoutId: record.id, force: true, deleteBranch: false }),
      ).rejects.toMatchObject({
        code: "WORKTREE_DELETE_FAILED",
        message: "The isolated worktree's directory could not be removed.",
      });
    });

    test("locates no holder that sits outside the checkout", async () => {
      // The two ways out, because `relative` answers them differently: a
      // sibling walks out with `..`, while a cross-root pair — another drive
      // letter, a UNC share — comes back ABSOLUTE, which no `..` test catches.
      // Either one named here would put the host's own directory layout into a
      // message that crosses the session wire.
      const record = await seed();
      const git = fakeGit(worktreePath, { removeExitCode: 1 });
      const holders = [
        { pid: 77, name: "sibling.exe", cwd: resolve(worktreePath, "..", "elsewhere") },
        { pid: 78, name: "crossroot.exe", cwd: process.platform === "win32" ? "Z:\\work" : "/etc" },
      ];
      await expect(
        manager(git.run, { listHolders: () => holders })
          .remove({ checkoutId: record.id, force: true, deleteBranch: false }),
      ).rejects.toThrow(/Held by sibling\.exe \(pid 77\), crossroot\.exe \(pid 78\)\.$/);
    });
  });

  test("refuses to remove an unregistered directory Antgrid does not own", async () => {
    // Refused because the path is not under Antgrid's worktree root, not
    // because the registration is missing — an owned path is reclaimed below.
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

  test("drops the checkout row even when the requested branch deletion fails", async () => {
    // The inverse of every case above, and the reason they are worth separating:
    // this failure lands AFTER `git worktree remove` has already succeeded. Git
    // refuses the branch for two ordinary reasons — the session renamed it away,
    // or the user checked it out in their own tree — and throwing here left a row
    // pointing at a directory that no longer exists, which no later delete could
    // clear because `inspect` reports the worktree missing.
    const record = await seed();
    const git = fakeGit(worktreePath, { branchDeleteExitCode: 1 });
    await manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: true });
    expect(await store().get(record.id)).toBeUndefined();
  });

  test("a rev-list that fails on a branch that still exists refuses the delete", async () => {
    // rev-list reports "nothing unpushed" and "I could not answer" identically:
    // empty stdout. Reading only stdout opens the guard on every failure, which
    // is the one direction that loses commits. The ref still being there means
    // there is something to lose, so an unforced delete has to refuse.
    const record = await seed();
    const git = fakeGit(worktreePath, { revListExitCode: 128, branchExists: true });
    await expect(manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_UNPUSHED" });
    expect(await store().get(record.id)).toMatchObject({ id: record.id });
  });

  test("a rev-list that fails because the branch is gone lets the delete through", async () => {
    // The one failure that really does mean nothing is at risk: whatever those
    // commits were, they are not reachable from a ref this delete touches.
    const record = await seed();
    const git = fakeGit(worktreePath, { revListExitCode: 128, branchExists: false });
    await manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false });
    expect(await store().get(record.id)).toBeUndefined();
  });

  test("a rev-list that fails because the repository is unreadable still refuses", async () => {
    // `show-ref` answers a gone branch and a broken repository identically, and
    // only the first means nothing is at risk. Reading the second as "nothing
    // unpushed" is what would let `branch -D` take commits with it.
    const record = await seed();
    const git = fakeGit(worktreePath, {
      revListExitCode: 128, branchExists: false, repoReadable: false,
    });
    await expect(
      manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false }),
    ).rejects.toMatchObject({ code: "WORKTREE_UNPUSHED" });
    expect(await store().get(record.id)).toBeDefined();
  });

  test("a checkout whose directory is gone still guards its unpushed commits", async () => {
    // The branch outlives the directory: `refs/heads` is in the repository, so
    // a `deleteBranch` here would drop commits nothing else holds.
    const record = await seed();
    rmSync(worktreePath, { recursive: true, force: true });
    const git = fakeGit(worktreePath, { unpushed: true });
    await expect(
      manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: true }),
    ).rejects.toMatchObject({ code: "WORKTREE_UNPUSHED" });
    expect(git.calls.some((args) => args.join(" ").startsWith("branch -D"))).toBe(false);
  });

  describe("directories Antgrid owns", () => {
    /** A checkout at the path `prepareForSession` would have derived. Ownership
     *  is decided on the path alone, so this is the only thing that separates
     *  these cases from the refusals above. */
    async function seedOwned(): Promise<{ record: CheckoutRecord; path: string }> {
      const path = join(abDir, "wt", projectId, "checkout-owned");
      mkdirSync(path, { recursive: true });
      writeFileSync(join(path, "readme.txt"), "work\n");
      const record = await seed({ id: "checkout-owned", path });
      return { record, path };
    }

    test("reclaims the directory when `git worktree remove` fails", async () => {
      // The failure that used to be permanent: Git aborts partway (on Windows,
      // one directory held open by an orphaned process is enough), and every
      // retry afterwards found a registration already pruned away.
      const { record, path } = await seedOwned();
      const git = fakeGit(path, { removeExitCode: 1 });
      await manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: false });

      expect(existsSync(path)).toBe(false);
      expect(await store().get(record.id)).toBeUndefined();
      expect(git.calls.some((args) => args.join(" ") === "worktree prune")).toBe(true);
    });

    test("reclaims a directory Git no longer registers, without asking it to remove one", async () => {
      const { record, path } = await seedOwned();
      const git = fakeGit(path, { registered: false });
      await manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: false });

      expect(existsSync(path)).toBe(false);
      expect(await store().get(record.id)).toBeUndefined();
      expect(git.calls.some((args) => args[1] === "remove")).toBe(false);
    });

    test("records Git's own words for a failed removal", async () => {
      // The analytics event carries a code and nothing else, so without this
      // line a support bundle cannot tell this failure from an unregistered one.
      const { record, path } = await seedOwned();
      const git = fakeGit(path, { removeExitCode: 1 });
      const lines: string[] = [];
      __setRootForTest({ write: (message: string) => { lines.push(message); } }, "warn");
      try {
        await manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: false });
      } finally {
        __setRootForTest(process.stdout, "info");
      }
      expect(lines.join("")).toContain("fake git failure");
    });

    test("treats a `git status` it cannot read as dirty while the checkout is still a checkout", async () => {
      // The reclaim is what makes this load-bearing: reading a failed status as
      // "clean" now ends in `rm -rf`, not in Git declining to touch anything.
      // A corrupt index and a moved gitdir both answer non-zero over a tree
      // still full of the user's work.
      const { record, path } = await seedOwned();
      mkdirSync(join(path, ".git"), { recursive: true });
      const git = fakeGit(path, { statusExitCode: 128 });
      await expect(manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false }))
        .rejects.toMatchObject({ code: "WORKTREE_DIRTY" });
      expect(existsSync(path)).toBe(true);
      expect(await store().get(record.id)).toMatchObject({ id: record.id });
    });

    test("still deletes wreckage whose `git status` fails because the `.git` link is gone", async () => {
      // The other side of the same branch, and the case the reclaim exists for:
      // there is nothing left to enumerate, so an unreadable status here means
      // empty, not unknown.
      const { record, path } = await seedOwned();
      const git = fakeGit(path, { statusExitCode: 128, registered: false });
      await manager(git.run).remove({ checkoutId: record.id, force: false, deleteBranch: false });
      expect(existsSync(path)).toBe(false);
      expect(await store().get(record.id)).toBeUndefined();
    });

    test("reclaims a checkout whose stored path is spelled through a symlink", async () => {
      // `abDir` reached one way, `record.path` stored realpath-resolved the
      // other: the shape every macOS run has, because `/tmp` and `/var` are
      // both symlinks there. A junction reproduces it on Windows without
      // elevation, so this guards the POSIX case from wherever CI runs.
      const real = mkdtempSync(join(tmpdir(), "antgrid-worktree-real-"));
      const link = join(mkdtempSync(join(tmpdir(), "antgrid-worktree-link-")), "home");
      symlinkSync(real, link, process.platform === "win32" ? "junction" : "dir");
      const linked = new CheckoutStore(link, projectId);
      const path = join(real, "wt", projectId, "checkout-linked");
      mkdirSync(path, { recursive: true });
      const record: CheckoutRecord = {
        id: "checkout-linked", projectId, kind: "managed-worktree", path,
        branch: BRANCH, baseRef: null, managed: true, sessionId: "session-1", createdAt: 1,
      };
      await linked.put(record);
      const git = fakeGit(path, { removeExitCode: 1 });
      const scoped = new WorktreeManager({
        abDir: link, git: git.run, resolveRepoPath: async (id) => (id === projectId ? repoPath : undefined),
      });
      try {
        await scoped.remove({ checkoutId: record.id, force: true, deleteBranch: false });
        expect(existsSync(path)).toBe(false);
        expect(await linked.get(record.id)).toBeUndefined();
      } finally {
        rmSync(real, { recursive: true, force: true });
      }
    });

    test("forces `worktree remove` twice so a locked entry cannot outlive its directory", async () => {
      // One `--force` still refuses a locked worktree and `worktree prune` skips
      // locked entries forever, so a single force would reclaim the directory
      // and strand the registration — losing the tree AND failing the delete.
      const { record, path } = await seedOwned();
      const git = fakeGit(path);
      await manager(git.run).remove({ checkoutId: record.id, force: true, deleteBranch: false });
      const removal = git.calls.find((args) => args[1] === "remove");
      expect(removal?.filter((arg) => arg === "--force")).toHaveLength(2);
    });
  });
});
