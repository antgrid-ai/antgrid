import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { checkBranchAgainstRemote, GitHelperError } from "../src/git-branches";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

async function commit(cwd: string, body: string) {
  writeFileSync(join(cwd, "f.txt"), body);
  await run(cwd, ["add", "."]);
  await run(cwd, ["commit", "-m", body]);
}

/** Bare repo as `origin` + a clone on `main`. A path remote keeps the whole
 *  suite offline — `ls-remote` never leaves the filesystem. */
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

describe("checkBranchAgainstRemote", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-remote-state-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("throws UNKNOWN_BRANCH for a branch that does not exist", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await expect(checkBranchAgainstRemote(work, "nope")).rejects.toBeInstanceOf(GitHelperError);
  });

  it("reports no-remote when the repository has no remotes", async () => {
    const solo = join(dir, "solo");
    await run(dir, ["init", "-b", "main", solo]);
    await run(solo, ["config", "user.email", "test@antgrid.local"]);
    await run(solo, ["config", "user.name", "Test"]);
    await commit(solo, "one");

    const res = await checkBranchAgainstRemote(solo, "main");
    expect(res.state).toBe("no-remote");
  });

  it("reports no-upstream for a branch the remote has never seen", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["branch", "local-only"]);

    const res = await checkBranchAgainstRemote(work, "local-only");
    expect(res.state).toBe("no-upstream");
    expect(res.remote).toBe("origin");
  });

  // `branch.<x>.remote = "."` tracks a LOCAL branch, so it is not evidence the
  // branch ever reached the remote — reading it as tracking config would call a
  // never-pushed branch `gone`.
  it("reports no-upstream for a branch that tracks a local branch", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["branch", "--track", "local-track", "main"]);
    await run(work, ["config", "branch.local-track.remote", "."]);
    await run(work, ["config", "branch.local-track.merge", "refs/heads/main"]);

    const res = await checkBranchAgainstRemote(work, "local-track");
    expect(res.state).toBe("no-upstream");
  });

  it("reports in-sync when the remote is at the same commit", async () => {
    const { work } = await makeRepoWithRemote(dir);

    const res = await checkBranchAgainstRemote(work, "main");
    expect(res.state).toBe("in-sync");
    expect(res.remote).toBe("origin");
    expect(res.remoteBranch).toBe("main");
  });

  // A side branch, not main: a bare repo's HEAD branch cannot be deleted, and
  // the silent no-op leaves the ref in place and the state in-sync.
  it("reports gone when the tracked branch was deleted on the remote", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["checkout", "-b", "feature"]);
    await run(work, ["push", "-u", "origin", "feature"]);
    await run(work, ["push", "origin", "--delete", "feature"]);

    const res = await checkBranchAgainstRemote(work, "feature");
    expect(res.state).toBe("gone");
  });

  it("reports ahead with a count for unpushed local commits", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await commit(work, "two");

    const res = await checkBranchAgainstRemote(work, "main");
    expect(res.state).toBe("ahead");
    expect(res.ahead).toBe(1);
    expect(res.behind).toBe(0);
  });

  // The headline case: the remote moved and this clone has not fetched, so the
  // remote commit is not a local object and counts are unknowable. A
  // `refs/remotes/*` comparison answers "in sync" here, which is the bug this
  // whole check exists to avoid.
  it("reports differs — not in-sync — when the remote moved and nobody fetched", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = join(dir, "other");
    await run(dir, ["clone", bare, other]);
    await run(other, ["config", "user.email", "test@antgrid.local"]);
    await run(other, ["config", "user.name", "Test"]);
    await commit(other, "two");
    await run(other, ["push", "origin", "main"]);

    const res = await checkBranchAgainstRemote(work, "main");
    expect(res.state).toBe("differs");
    expect(res.behind).toBeUndefined();
    expect(res.ahead).toBeUndefined();
  });

  it("upgrades differs to behind with counts once the objects are local", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = join(dir, "other");
    await run(dir, ["clone", bare, other]);
    await run(other, ["config", "user.email", "test@antgrid.local"]);
    await run(other, ["config", "user.name", "Test"]);
    await commit(other, "two");
    await run(other, ["push", "origin", "main"]);
    await run(work, ["fetch"]);

    const res = await checkBranchAgainstRemote(work, "main");
    expect(res.state).toBe("behind");
    expect(res.behind).toBe(1);
    expect(res.ahead).toBe(0);
  });

  it("reports diverged with both counts", async () => {
    const { bare, work } = await makeRepoWithRemote(dir);
    const other = join(dir, "other");
    await run(dir, ["clone", bare, other]);
    await run(other, ["config", "user.email", "test@antgrid.local"]);
    await run(other, ["config", "user.name", "Test"]);
    await commit(other, "remote-side");
    await run(other, ["push", "origin", "main"]);
    await run(work, ["fetch"]);
    await commit(work, "local-side");

    const res = await checkBranchAgainstRemote(work, "main");
    expect(res.state).toBe("diverged");
    expect(res.behind).toBe(1);
    expect(res.ahead).toBe(1);
  });

  it("reports unreachable instead of hanging when the remote does not resolve", async () => {
    const { work } = await makeRepoWithRemote(dir);
    await run(work, ["remote", "set-url", "origin", join(dir, "does-not-exist.git")]);

    const res = await checkBranchAgainstRemote(work, "main");
    expect(res.state).toBe("unreachable");
  });
});
