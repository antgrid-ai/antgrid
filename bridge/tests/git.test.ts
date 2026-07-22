// bridge/tests/git.test.ts
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { getGitStatus, gitCommit, gitDiscard } from "../src/git";

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

  it("reports modified tracked files and untracked files", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");      // modify
    writeFileSync(join(dir, "new.txt"), "new\n");          // untracked
    const status = await getGitStatus(dir);
    expect(status).toContainEqual({ path: "tracked.txt", status: "M" });
    expect(status).toContainEqual({ path: "new.txt", status: "?" });
  });

  it("commits only the selected files", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    writeFileSync(join(dir, "new.txt"), "new\n");
    const res = await gitCommit(dir, "msg", ["new.txt"]);
    expect(res.success).toBe(true);
    expect(res.sha).toBeTruthy();
    const after = await getGitStatus(dir);
    // new.txt committed and gone; tracked.txt still modified
    expect(after).toContainEqual({ path: "tracked.txt", status: "M" });
    expect(after.find((e) => e.path === "new.txt")).toBeUndefined();
  });

  it("rejects empty message and empty selection", async () => {
    expect((await gitCommit(dir, "  ", ["new.txt"])).success).toBe(false);
    expect((await gitCommit(dir, "msg", [])).success).toBe(false);
  });

  it("does not sweep in files staged out-of-band", async () => {
    writeFileSync(join(dir, "tracked.txt"), "v2\n");
    writeFileSync(join(dir, "other.txt"), "other\n");
    await run(dir, ["add", "other.txt"]); // staged out-of-band, NOT selected
    const res = await gitCommit(dir, "msg", ["tracked.txt"]);
    expect(res.success).toBe(true);
    // other.txt stays uncommitted (still present as a change after the commit)
    const after = await getGitStatus(dir);
    expect(after.find((e) => e.path === "other.txt")).toBeTruthy();
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
    expect(status).toContainEqual({ path: "café.txt", status: "?" });
    const res = await gitDiscard(dir, ["café.txt"]);
    expect(res.success).toBe(true);
    expect(await getGitStatus(dir)).toEqual([]);
  });
});
