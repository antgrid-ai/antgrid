// bridge/tests/git.test.ts
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { getGitStatus, gitCommit, gitDiscard, gitStage, gitUnstage } from "../src/git";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

describe("git helpers", () => {
  let dir: string;

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-git-test-"));
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "tracked.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "init"]);
  });

  afterEach(() => rmSync(dir, { recursive: true, force: true }));

  it("reports modified tracked files and untracked files, both unstaged", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");      // modify, not staged
    writeFileSync(join(dir, "new.txt"), "new\n");          // untracked
    const status = await getGitStatus(dir);
    expect(status).toContainEqual({
      path: "tracked.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 1,
    });
    expect(status).toContainEqual({
      path: "new.txt",
      status: "U",
      staged: false,
      additions: 1,
      deletions: 0,
    });
  });

  it("gitStage moves a modified file into the staged bucket", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    const res = await gitStage(dir, ["tracked.txt"]);
    expect(res.success).toBe(true);
    const status = await getGitStatus(dir);
    expect(status).toEqual([
      { path: "tracked.txt", status: "M", staged: true, additions: 1, deletions: 1 },
    ]);
  });

  it("gitUnstage moves it back to unstaged without touching the working tree", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    await gitStage(dir, ["tracked.txt"]);
    const res = await gitUnstage(dir, ["tracked.txt"]);
    expect(res.success).toBe(true);
    const status = await getGitStatus(dir);
    expect(status).toEqual([
      { path: "tracked.txt", status: "M", staged: false, additions: 1, deletions: 1 },
    ]);
  });

  it("reports a file with both a staged and a further unstaged edit as two entries", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    await gitStage(dir, ["tracked.txt"]);
    writeFileSync(join(dir, "tracked.txt"), "v3\n"); // edited again after staging
    const status = await getGitStatus(dir);
    // Both entries carry the SAME totals — the combined diff vs HEAD ("v1"
    // straight to "v3"), not a per-bucket split.
    expect(status).toContainEqual({
      path: "tracked.txt",
      status: "M",
      staged: true,
      additions: 1,
      deletions: 1,
    });
    expect(status).toContainEqual({
      path: "tracked.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 1,
    });
    expect(status).toHaveLength(2);
  });

  it("commits whatever is staged", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    writeFileSync(join(dir, "new.txt"), "new\n");
    await gitStage(dir, ["new.txt"]);
    const res = await gitCommit(dir, "msg");
    expect(res.success).toBe(true);
    expect(res.sha).toBeTruthy();
    const after = await getGitStatus(dir);
    // new.txt committed and gone; tracked.txt (never staged) still shows unstaged
    expect(after).toContainEqual({
      path: "tracked.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 1,
    });
    expect(after.find((e) => e.path === "new.txt")).toBeUndefined();
  });

  it("rejects an empty message", async () => {
    await gitStage(dir, []);
    expect((await gitCommit(dir, "  ")).success).toBe(false);
  });

  it("rejects a commit with nothing staged", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n"); // modified but never staged
    expect((await gitCommit(dir, "msg")).success).toBe(false);
  });

  it("commits everything staged, including files staged out-of-band", async () => {
    // Unlike the old file-scoped commit, a real staging model means Commit
    // commits the index as-is — anything staged by another process included.
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    writeFileSync(join(dir, "other.txt"), "other\n");
    await run(dir, ["add", "other.txt"]); // staged out-of-band, via raw git
    const res = await gitCommit(dir, "msg");
    expect(res.success).toBe(true);
    const after = await getGitStatus(dir);
    expect(after.find((e) => e.path === "other.txt")).toBeUndefined(); // committed
    expect(after).toContainEqual({
      path: "tracked.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 1,
    }); // left alone
  });

  it("discards a tracked modification (restore)", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    const res = await gitDiscard(dir, ["tracked.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(dir)).toEqual([]);
  });

  it("discards an untracked file (clean)", async () => {
    writeFileSync(join(dir, "new.txt"), "new\n");
    const res = await gitDiscard(dir, ["new.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(dir)).toEqual([]);
  });

  it("classifies tracked vs untracked from live git, not a passed snapshot", async () => {
    // A tracked modification AND an untracked file discarded together: the
    // function must restore one and clean the other based on live state.
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    writeFileSync(join(dir, "new.txt"), "new\n");
    const res = await gitDiscard(dir, ["tracked.txt", "new.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(dir)).toEqual([]);
  });

  it("handles non-ASCII filenames (core.quotepath off)", async () => {
    // Without core.quotepath=false, git emits 'caf\303\251.txt' and the path
    // round-trips into pathspecs that match nothing.
    writeFileSync(join(dir, "café.txt"), "x\n");
    const status = await getGitStatus(dir);
    expect(status).toContainEqual({
      path: "café.txt",
      status: "U",
      staged: false,
      additions: 1,
      deletions: 0,
    });
    const res = await gitDiscard(dir, ["café.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(dir)).toEqual([]);
  });

  it("reports a staged rename as R with oldPath, not D+U", async () => {
    await run(dir, ["mv", "tracked.txt", "renamed.txt"]);
    const status = await getGitStatus(dir);
    // Pure rename, no content change: 0/0, not the 1/1 a naive delete+add
    // numstat pairing would otherwise show — `-M` rename pairing is what
    // makes that possible.
    expect(status).toEqual([
      {
        path: "renamed.txt",
        status: "R",
        staged: true,
        oldPath: "tracked.txt",
        additions: 0,
        deletions: 0,
      },
    ]);
  });

  // The two tests above both happen to survive a broken numstat parse — one
  // asserts the same 0/0 the miss-path falls back to, the other only passes
  // because git leaves that rename UNPAIRED and emits the new path's record
  // first. These two pin the paired case, where the `-z` record carries an
  // EMPTY path field and both halves follow as separate tokens.
  it("a rename git pairs in the diff keeps its real +/- counts", async () => {
    writeFileSync(join(dir, "big.txt"), "alpha\nbeta\ngamma\ndelta\nepsilon\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "add big"]);
    await run(dir, ["mv", "big.txt", "moved.txt"]);
    // Similar enough that `-M` pairs it, unlike the 1-line files above.
    writeFileSync(join(dir, "moved.txt"), "alpha\nbeta\ngamma\ndelta\nepsilon\nzeta\n");

    const status = await getGitStatus(dir);
    expect(status).toContainEqual({
      path: "moved.txt",
      status: "R",
      staged: true,
      oldPath: "big.txt",
      additions: 1,
      deletions: 0,
    });
  });

  it("a rename does not swallow the diff stats of the file sorted after it", async () => {
    // The old parse treated any path matching a rename's OLD path as a
    // marker that the NEXT record was its key, consuming an unrelated file's
    // record whole. `a.txt` (the old path) sorts before `m.txt`, which is
    // what put `m.txt` in the line of fire.
    writeFileSync(join(dir, "a.txt"), "one\n");
    writeFileSync(join(dir, "m.txt"), "keep\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "add a and m"]);
    await run(dir, ["mv", "a.txt", "z.txt"]);
    writeFileSync(join(dir, "z.txt"), "totally different content here\n");
    writeFileSync(join(dir, "m.txt"), "keep\nplus one more line\n");

    const status = await getGitStatus(dir);
    expect(status).toContainEqual({
      path: "m.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 0,
    });
  });

  it("reports a renamed-and-edited file as a staged rename PLUS an unstaged modification", async () => {
    // A path can legitimately appear twice — same as VS Code showing it once
    // under Staged Changes (the rename) and once under Changes (the edit).
    await run(dir, ["mv", "tracked.txt", "renamed.txt"]);
    writeFileSync(join(dir, "renamed.txt"), "v2\n");
    const status = await getGitStatus(dir);
    expect(status).toContainEqual({
      path: "renamed.txt",
      status: "R",
      staged: true,
      oldPath: "tracked.txt",
      additions: 1,
      deletions: 0,
    });
    expect(status).toContainEqual({
      path: "renamed.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 0,
    });
    expect(status).toHaveLength(2);
  });

  it("reports a merge conflict as ! and excludes it from M/A/D/U", async () => {
    await run(dir, ["checkout", "-b", "feature"]);
    writeFileSync(join(dir, "tracked.txt"), "feature\n");
    await run(dir, ["commit", "-am", "feature change"]);
    await run(dir, ["checkout", "-"]);
    writeFileSync(join(dir, "tracked.txt"), "main\n");
    await run(dir, ["commit", "-am", "main change"]);
    await run(dir, ["merge", "feature"]); // exits non-zero on conflict; fire-and-forget helper ignores exit code
    const status = await getGitStatus(dir);
    expect(status).toEqual([
      { path: "tracked.txt", status: "!", staged: false, additions: 0, deletions: 0 },
    ]);
  });

  it("discarding a rename restores the old path and removes the new one", async () => {
    await run(dir, ["mv", "tracked.txt", "renamed.txt"]);
    const res = await gitDiscard(dir, ["renamed.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(dir)).toEqual([]);
  });

  it("unstaging a rename restores both the old and new path index entries cleanly", async () => {
    await run(dir, ["mv", "tracked.txt", "renamed.txt"]);
    const res = await gitUnstage(dir, ["renamed.txt"]);
    expect(res.success).toBe(true);
    const status = await getGitStatus(dir);
    // No residual phantom staged-deletion of tracked.txt — the physical move
    // is still visible as an unstaged delete (old path) + untracked (new path).
    expect(status).toContainEqual({
      path: "tracked.txt",
      status: "D",
      staged: false,
      additions: 0,
      deletions: 1,
    });
    expect(status).toContainEqual({
      path: "renamed.txt",
      status: "U",
      staged: false,
      additions: 1,
      deletions: 0,
    });
    expect(status).toHaveLength(2);
  });
});

// A project the user added is not necessarily a repository ROOT — a folder
// inside a monorepo is an ordinary thing to open. Porcelain reports from the
// repo root and has no `--relative`, so everything here is about the project
// seeing its own subtree, under paths that match its file tree.
describe("git helpers in a repo SUBDIRECTORY", () => {
  let repo: string;
  let project: string; // <repo>/sub — what the bridge is handed

  beforeEach(async () => {
    repo = mkdtempSync(join(tmpdir(), "antgrid-git-sub-test-"));
    project = join(repo, "sub");
    mkdirSync(project);
    mkdirSync(join(repo, "elsewhere"));
    await run(repo, ["init"]);
    await run(repo, ["config", "user.email", "test@antgrid.local"]);
    await run(repo, ["config", "user.name", "Test"]);
    writeFileSync(join(repo, "outside.txt"), "o\n");
    writeFileSync(join(project, "inside.txt"), "i\n");
    writeFileSync(join(repo, "elsewhere", "cross.txt"), "c\n");
    await run(repo, ["add", "."]);
    await run(repo, ["commit", "-m", "init"]);
  });

  afterEach(() => rmSync(repo, { recursive: true, force: true }));

  it("reports only its own subtree, under project-relative paths", async () => {
    writeFileSync(join(repo, "outside.txt"), "o2\n"); // another project's business
    writeFileSync(join(project, "inside.txt"), "i2\n");
    writeFileSync(join(project, "untracked.txt"), "new\n");

    const status = await getGitStatus(project);
    // "sub/inside.txt" would match no node in a tree rooted at the project.
    expect(status).toContainEqual({
      path: "inside.txt",
      status: "M",
      staged: false,
      additions: 1,
      deletions: 1,
    });
    expect(status).toContainEqual({
      path: "untracked.txt",
      status: "U",
      staged: false,
      additions: 1,
      deletions: 0,
    });
    expect(status.map((e) => e.path).sort()).toEqual([
      "inside.txt",
      "untracked.txt",
    ]);
  });

  it("keeps a rename inside the project, with a project-relative oldPath", async () => {
    await run(project, ["mv", "inside.txt", "moved.txt"]);
    const status = await getGitStatus(project);
    expect(status).toEqual([
      {
        path: "moved.txt",
        status: "R",
        staged: true,
        oldPath: "inside.txt",
        additions: 0,
        deletions: 0,
      },
    ]);
  });

  it("reports a rename INTO the project as a plain add, not an unnameable rename", async () => {
    // The old path lies outside the project, so there is no project-relative
    // name for it — and a repo-root-relative one would resolve wrong against
    // every pathspec this module hands back to git.
    await run(repo, ["mv", "elsewhere/cross.txt", "sub/cross.txt"]);
    const status = await getGitStatus(project);
    expect(status).toEqual([
      { path: "cross.txt", status: "A", staged: true, additions: 1, deletions: 0 },
    ]);
  });

  it("stage/unstage/discard act on project-relative paths", async () => {
    writeFileSync(join(project, "inside.txt"), "i2\n");

    expect((await gitStage(project, ["inside.txt"])).success).toBe(true);
    expect(await getGitStatus(project)).toEqual([
      { path: "inside.txt", status: "M", staged: true, additions: 1, deletions: 1 },
    ]);

    expect((await gitUnstage(project, ["inside.txt"])).success).toBe(true);
    expect(await getGitStatus(project)).toEqual([
      { path: "inside.txt", status: "M", staged: false, additions: 1, deletions: 1 },
    ]);

    expect((await gitDiscard(project, ["inside.txt"])).success).toBe(true);
    expect(await getGitStatus(project)).toEqual([]);
  });

  it("discarding a rename inside the project restores the old path", async () => {
    await run(project, ["mv", "inside.txt", "moved.txt"]);
    const res = await gitDiscard(project, ["moved.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(project)).toEqual([]);
  });
});
