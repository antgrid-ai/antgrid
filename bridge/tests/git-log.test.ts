import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { getGitLog, getCommitFiles, getCommitFileDiff } from "../src/git-log";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

describe("git-log helper", () => {
  let dir: string;

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-log-test-"));
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns an empty page with no repository history", async () => {
    const res = await getGitLog(dir, 0, 10);
    expect(res).toEqual({ commits: [], hasMore: false });
  });

  it("lists commits newest-first with correct subject/author fields", async () => {
    writeFileSync(join(dir, "a.txt"), "1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "first commit"]);
    writeFileSync(join(dir, "a.txt"), "2\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "second commit"]);

    const res = await getGitLog(dir, 0, 10);
    expect(res.hasMore).toBe(false);
    expect(res.commits).toHaveLength(2);
    expect(res.commits[0]!.subject).toBe("second commit");
    expect(res.commits[1]!.subject).toBe("first commit");
    expect(res.commits[0]!.sha).toHaveLength(40);
    expect(res.commits[0]!.shortSha.length).toBeGreaterThan(0);
    expect(res.commits[0]!.authorName).toBe("Test");
    expect(res.commits[0]!.authorEmail).toBe("test@antgrid.local");
    expect(res.commits[0]!.authorDate.length).toBeGreaterThan(0);
  });

  it("paginates with skip/limit and reports hasMore", async () => {
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(dir, "a.txt"), `${i}\n`);
      await run(dir, ["add", "."]);
      await run(dir, ["commit", "-m", `commit ${i}`]);
    }

    const page1 = await getGitLog(dir, 0, 2);
    expect(page1.commits.map((c) => c.subject)).toEqual(["commit 4", "commit 3"]);
    expect(page1.hasMore).toBe(true);

    const page2 = await getGitLog(dir, 2, 2);
    expect(page2.commits.map((c) => c.subject)).toEqual(["commit 2", "commit 1"]);
    expect(page2.hasMore).toBe(true);

    const page3 = await getGitLog(dir, 4, 2);
    expect(page3.commits.map((c) => c.subject)).toEqual(["commit 0"]);
    expect(page3.hasMore).toBe(false);
  });

  it("lists a root commit's files against the empty tree", async () => {
    writeFileSync(join(dir, "a.txt"), "one\n");
    writeFileSync(join(dir, "b.txt"), "two\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    const { commits } = await getGitLog(dir, 0, 10);
    const files = await getCommitFiles(dir, commits[0]!.sha);
    const byPath = Object.fromEntries(files.map((f) => [f.path, f]));
    expect(byPath["a.txt"]).toMatchObject({ status: "A", additions: 1, deletions: 0 });
    expect(byPath["b.txt"]).toMatchObject({ status: "A", additions: 1, deletions: 0 });
  });

  it("reports a modify + a detected rename in one commit", async () => {
    writeFileSync(join(dir, "keep.txt"), "same\n");
    writeFileSync(join(dir, "old.txt"), "line one\nline two\nline three\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    writeFileSync(join(dir, "keep.txt"), "same\nmodified\n");
    await run(dir, ["mv", "old.txt", "new.txt"]);
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "modify and rename"]);

    const { commits } = await getGitLog(dir, 0, 10);
    const files = await getCommitFiles(dir, commits[0]!.sha);
    const byPath = Object.fromEntries(files.map((f) => [f.path, f]));

    expect(byPath["keep.txt"]).toMatchObject({ status: "M" });
    expect(byPath["keep.txt"]!.additions).toBeGreaterThan(0);
    expect(byPath["new.txt"]).toMatchObject({ status: "R", oldPath: "old.txt" });
    expect(byPath["old.txt"]).toBeUndefined();
  });

  it("returns a unified diff for one file within a commit", async () => {
    writeFileSync(join(dir, "a.txt"), "one\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);
    writeFileSync(join(dir, "a.txt"), "one\ntwo\n");
    await run(dir, ["commit", "-am", "add line"]);

    const { commits } = await getGitLog(dir, 0, 10);
    const res = await getCommitFileDiff(dir, commits[0]!.sha, "a.txt");
    expect(res.diff).toContain("+two");
    expect(res.additions).toBe(1);
    expect(res.deletions).toBe(0);
  });

  it("returns null diff for a path the commit did not touch", async () => {
    writeFileSync(join(dir, "a.txt"), "one\n");
    writeFileSync(join(dir, "untouched.txt"), "same\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);
    writeFileSync(join(dir, "a.txt"), "one\ntwo\n");
    await run(dir, ["commit", "-am", "add line"]);

    const { commits } = await getGitLog(dir, 0, 10);
    const res = await getCommitFileDiff(dir, commits[0]!.sha, "untouched.txt");
    expect(res.diff).toBeNull();
  });
});
