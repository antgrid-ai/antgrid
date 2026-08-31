import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { classifySyncFailure, gitPull, gitPush, readSyncState } from "../src/git-sync";
import type { GitSyncFailureKind } from "../src/git-sync";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

async function capture(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const out = await new Response(proc.stdout).text();
  await proc.exited;
  return out.trim();
}

async function commit(cwd: string, body: string) {
  writeFileSync(join(cwd, "f.txt"), body);
  await run(cwd, ["add", "."]);
  await run(cwd, ["commit", "-m", body]);
}

/** Bare repo as `origin` + a clone on `main`. A path remote keeps the whole
 *  suite offline — no push or fetch here ever leaves the filesystem. Same
 *  fixture shape as git-branch-remote-state.test.ts. */
async function makeRepoWithRemote(root: string) {
  const bare = join(root, "origin.git");
  const work = join(root, "work");
  await run(root, ["init", "--bare", "-b", "main", bare]);
  await run(root, ["clone", bare, work]);
  await run(work, ["config", "user.email", "test@antgrid.local"]);
  await run(work, ["config", "user.name", "Test"]);
  await run(work, ["checkout", "-b", "main"]);
  await commit(work, "one");
  await run(work, ["push", "-u", "origin", "main"]);
  return { bare, work };
}

/** A second clone, used to advance `origin` behind the first one's back. */
async function makeSecondClone(root: string, bare: string) {
  const other = join(root, "other");
  await run(root, ["clone", bare, other]);
  await run(other, ["config", "user.email", "other@antgrid.local"]);
  await run(other, ["config", "user.name", "Other"]);
  return other;
}

describe("readSyncState", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-git-sync-")); });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("reports a freshly pushed branch as level with its upstream", async () => {
    const { work } = await makeRepoWithRemote(dir);
    const state = await readSyncState(work);
    expect(state).toMatchObject({
      branch: "main",
      remote: "origin",
      remoteBranch: "main",
      ahead: 0,
      behind: 0,
      hasUpstream: true,
      hasRemote: true,
    });
  });

  it("counts local commits as ahead", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await commit(work, "two");
    await commit(work, "three");
    const state = await readSyncState(work);
    expect(state.ahead).toBe(2);
    expect(state.behind).toBe(0);
  });

  it("counts fetched-but-unmerged commits as behind", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = await makeSecondClone(dir, bare);
    await commit(other, "remote-two");
    await run(other, ["push"]);

    // The counts read `refs/remotes`, so they move on the FETCH — which is the
    // documented contract, and why pulling is what refreshes the indicator.
    await run(work, ["fetch", "origin", "main"]);
    const state = await readSyncState(work);
    expect(state.behind).toBe(1);
    expect(state.ahead).toBe(0);
  });

  it("reports a branch with no upstream, without inventing counts", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["checkout", "-b", "feature"]);
    await commit(work, "feature-one");

    const state = await readSyncState(work);
    expect(state.hasUpstream).toBe(false);
    expect(state.hasRemote).toBe(true);
    // `resolvePushTarget` guesses same-name-on-origin, which is what a first
    // push would create — but the counts stay 0 rather than being guessed too.
    expect(state.remote).toBe("origin");
    expect(state.ahead).toBe(0);
    expect(state.behind).toBe(0);
  });

  it("reports a repository with no remote at all", async () => {
    const solo = join(dir, "solo");
    await run(dir, ["init", "-b", "main", solo]);
    await run(solo, ["config", "user.email", "test@antgrid.local"]);
    await run(solo, ["config", "user.name", "Test"]);
    await commit(solo, "one");

    const state = await readSyncState(solo);
    expect(state).toMatchObject({ branch: "main", hasRemote: false, hasUpstream: false });
  });

  it("reports a detached HEAD as having no branch, but keeps hasRemote", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await commit(work, "two");
    const head = await capture(work, ["rev-parse", "HEAD~1"]);
    await run(work, ["checkout", "--detach", head]);

    const state = await readSyncState(work);
    // `rev-parse --abbrev-ref` answers the literal "HEAD" here; reporting that
    // as a branch name would hand it to push/pull as one.
    expect(state.branch).toBeNull();
    expect(state.hasRemote).toBe(true);
  });
});

describe("gitPush", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-git-push-")); });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("pushes local commits and clears the ahead count", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await commit(work, "two");

    const res = await gitPush(work);
    expect(res.success).toBe(true);
    expect(res.branch).toBe("main");
    expect(await readSyncState(work)).toMatchObject({ ahead: 0, behind: 0 });
  });

  it("sets an upstream on a branch that has none", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["checkout", "-b", "feature"]);
    await commit(work, "feature-one");

    const res = await gitPush(work);
    expect(res.success).toBe(true);
    expect(await capture(work, ["config", "--get", "branch.feature.remote"])).toBe("origin");
    expect(await readSyncState(work)).toMatchObject({ hasUpstream: true, ahead: 0 });
  });

  it("refuses a first push when several remotes and no origin make the target a guess", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const second = join(dir, "second.git");
    await run(dir, ["init", "--bare", "-b", "main", second]);
    await run(work, ["remote", "rename", "origin", "alpha"]);
    await run(work, ["remote", "add", "beta", second]);
    await run(work, ["checkout", "-b", "feature"]);
    await commit(work, "feature-one");

    const res = await gitPush(work);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("ambiguous-remote");
    // Nothing was published to either remote.
    expect(await capture(bare, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]))
      .not.toContain("feature");
  });

  it("reports no-remote in a repository with none", async () => {
    const solo = join(dir, "solo");
    await run(dir, ["init", "-b", "main", solo]);
    await run(solo, ["config", "user.email", "test@antgrid.local"]);
    await run(solo, ["config", "user.name", "Test"]);
    await commit(solo, "one");

    const res = await gitPush(solo);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("no-remote");
  });

  it("reports a detached HEAD rather than pushing from one", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await commit(work, "two");
    await run(work, ["checkout", "--detach", await capture(work, ["rev-parse", "HEAD"])]);

    const res = await gitPush(work);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("detached");
    expect(res.branch).toBeNull();
  });

  it("returns the rejection intact when the remote has moved on, and force-pushes nothing", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = await makeSecondClone(dir, bare);
    await commit(other, "remote-two");
    await run(other, ["push"]);
    const remoteHead = await capture(other, ["rev-parse", "HEAD"]);

    await commit(work, "local-two");
    const localHead = await capture(work, ["rev-parse", "HEAD"]);

    const res = await gitPush(work);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("not-fast-forward");
    // The two halves the agent handoff forwards.
    expect(res.command).toContain("git push");
    expect(res.stderr && res.stderr.length).toBeGreaterThan(0);
    // The remote still holds the OTHER clone's commit — nothing was forced over
    // it — and the local branch is untouched.
    expect(await capture(bare, ["rev-parse", "refs/heads/main"])).toBe(remoteHead);
    expect(await capture(work, ["rev-parse", "HEAD"])).toBe(localHead);
  });
});

describe("gitPull", () => {
  let dir: string;
  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-git-pull-")); });
  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("fast-forwards onto the remote's new commits", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = await makeSecondClone(dir, bare);
    await commit(other, "remote-two");
    await run(other, ["push"]);
    const remoteHead = await capture(other, ["rev-parse", "HEAD"]);

    const res = await gitPull(work);
    expect(res.success).toBe(true);
    expect(await capture(work, ["rev-parse", "HEAD"])).toBe(remoteHead);
    expect(await readSyncState(work)).toMatchObject({ ahead: 0, behind: 0 });
  });

  it("reports already-up-to-date without moving HEAD", async () => {
    const { work } = await makeRepoWithRemote(dir);
    const before = await capture(work, ["rev-parse", "HEAD"]);

    const res = await gitPull(work);
    expect(res.success).toBe(true);
    expect(res.summary).toBe("Already up to date");
    expect(await capture(work, ["rev-parse", "HEAD"])).toBe(before);
  });

  it("leaves HEAD and the worktree byte-identical on a diverged branch", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = await makeSecondClone(dir, bare);
    await commit(other, "remote-two");
    await run(other, ["push"]);

    await commit(work, "local-two");
    const before = await capture(work, ["rev-parse", "HEAD"]);
    const beforeFile = readFileSync(join(work, "f.txt"), "utf8");

    const res = await gitPull(work);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("diverged");
    // The whole safety property of --ff-only: no merge commit, no rebase in
    // progress, no conflict markers written into the tree.
    expect(await capture(work, ["rev-parse", "HEAD"])).toBe(before);
    expect(readFileSync(join(work, "f.txt"), "utf8")).toBe(beforeFile);
    expect(await capture(work, ["status", "--porcelain"])).toBe("");
  });

  it("refuses while the checkout holds unresolved merge conflicts", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["checkout", "-b", "side"]);
    await commit(work, "side-change");
    await run(work, ["checkout", "main"]);
    await commit(work, "main-change");
    await run(work, ["merge", "side"]);

    const res = await gitPull(work);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("conflict");
  });

  it("reports a detached HEAD rather than pulling onto one", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["checkout", "--detach", await capture(work, ["rev-parse", "HEAD"])]);

    const res = await gitPull(work);
    expect(res.success).toBe(false);
    expect(res.failureKind).toBe("detached");
  });
});

describe("classifySyncFailure", () => {
  // Every string here is real git output. The point of the table is that these
  // keep classifying correctly as git rewords itself between versions — which
  // is also why the app is never allowed to parse them itself.
  const cases: Array<[string, GitSyncFailureKind]> = [
    [
      "! [rejected]        main -> main (non-fast-forward)\nerror: failed to push some refs to '/tmp/origin.git'",
      "not-fast-forward",
    ],
    [
      "! [rejected]        main -> main (fetch first)\nerror: failed to push some refs",
      "not-fast-forward",
    ],
    ["fatal: Not possible to fast-forward, aborting.", "diverged"],
    [
      "fatal: Need to specify how to reconcile divergent branches.",
      "diverged",
    ],
    [
      "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
      "auth",
    ],
    ["git@github.com: Permission denied (publickey).", "auth"],
    ["remote: Invalid username or token. Password authentication is not supported.", "auth"],
    [
      "error: Your local changes to the following files would be overwritten by merge:\n\tf.txt",
      "dirty-tree",
    ],
    ["fatal: repository 'https://example.invalid/x.git' not found", "no-remote"],
    ["fatal: The current branch feature has no upstream branch.", "no-upstream"],
    ["", "unknown"],
  ];

  for (const [stderr, expected] of cases) {
    it(`classifies ${JSON.stringify(stderr.slice(0, 44))} as ${expected}`, () => {
      expect(classifySyncFailure(stderr, 1)).toBe(expected);
    });
  }

  it("classifies the timeout sentinel as unknown", () => {
    // A hung credential prompt and a black-holed host are indistinguishable
    // from here, so `unknown` is the honest answer rather than a guess.
    expect(classifySyncFailure("git push exceeded 120000ms", 124)).toBe("unknown");
  });

  it("prefers the non-fast-forward reading over the bare rejection", () => {
    // Both words appear in the same stderr; the more specific one is what the
    // app branches its copy on.
    expect(
      classifySyncFailure("! [rejected] main -> main (non-fast-forward)", 1),
    ).toBe("not-fast-forward");
  });
});
