import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { listLocalBranches, checkoutLocalBranch, listStashes, stashPop, stashDrop, GitHelperError } from "../src/git-branches";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

describe("git-branches helper", () => {
  let dir: string;

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-branches-test-"));
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("returns isRepository: false for a non-Git directory", async () => {
    const res = await listLocalBranches(dir);
    expect(res).toEqual({
      isRepository: false,
      current: null,
      branches: [],
      worktreeSessionsSupported: false,
    });
  });

  it("lists current and local branches in an attached repository sorted correctly", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "init.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    // Create additional branches
    await run(dir, ["branch", "feature-z"]);
    await run(dir, ["branch", "alpha"]);
    await run(dir, ["branch", "ALPHA-2"]);

    // Get branch listing while on default branch (master or main)
    const catalog = await listLocalBranches(dir);
    expect(catalog.isRepository).toBe(true);
    expect(catalog.current).toBeTruthy();
    expect(catalog.branches[0]).toBe(catalog.current!);

    // Check remaining branches sorting (case-insensitive)
    const expectedSorted = ["ALPHA-2", "alpha", "feature-z"];
    for (const b of expectedSorted) {
      expect(catalog.branches).toContain(b);
    }
  });

  it("handles detached HEAD with current: null while listing local branches", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "init.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "c1"]);
    await run(dir, ["branch", "main-branch"]);

    // Get HEAD commit hash and checkout commit hash directly (detached HEAD)
    const proc = Bun.spawn(["git", "rev-parse", "HEAD"], { cwd: dir, stdout: "pipe" });
    const headHash = (await new Response(proc.stdout).text()).trim();
    await proc.exited;

    await run(dir, ["checkout", headHash]);

    const catalog = await listLocalBranches(dir);
    expect(catalog.isRepository).toBe(true);
    expect(catalog.current).toBeNull();
    expect(catalog.branches).toContain("main-branch");
  });

  it("returns current branch without invoking switch when already on requested branch", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "init.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    const catalog = await listLocalBranches(dir);
    const current = catalog.current!;

    const res = await checkoutLocalBranch(dir, current);
    expect(res).toEqual({ current });
  });

  it("switches branch successfully when valid branch is specified", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "init.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);
    await run(dir, ["branch", "dev"]);

    const res = await checkoutLocalBranch(dir, "dev");
    expect(res).toEqual({ current: "dev" });

    const catalog = await listLocalBranches(dir);
    expect(catalog.current).toBe("dev");
  });

  it("throws NOT_GIT_REPOSITORY on a non-Git folder checkout", async () => {
    try {
      await checkoutLocalBranch(dir, "main");
      expect(true).toBe(false);
    } catch (err: any) {
      expect(err).toBeInstanceOf(GitHelperError);
      expect(err.code).toBe("NOT_GIT_REPOSITORY");
    }
  });

  it("throws UNKNOWN_BRANCH when attempting to checkout non-existent branch", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "init.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    try {
      await checkoutLocalBranch(dir, "non-existent-branch");
      expect(true).toBe(false);
    } catch (err: any) {
      expect(err).toBeInstanceOf(GitHelperError);
      expect(err.code).toBe("UNKNOWN_BRANCH");
    }
  });

  it("refuses a branch name Git would read as an option", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "init.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);
    await run(dir, ["branch", "dev"]);
    await run(dir, ["switch", "dev"]);
    await run(dir, ["switch", "-"]);
    const before = (await listLocalBranches(dir)).current;

    // Both of these exit 0 and move HEAD if they reach argv: `-` is @{-1} and
    // `--detach` detaches. The tree must be exactly where it was.
    for (const name of ["-", "--detach"]) {
      await expect(checkoutLocalBranch(dir, name)).rejects.toMatchObject({ code: "UNKNOWN_BRANCH" });
      expect((await listLocalBranches(dir)).current).toBe(before);
    }
  });

  it("checks out a branch that exists only on the remote", async () => {
    // The local-heads catalog is advisory: `git switch` DWIMs origin/<name>
    // into a tracking branch, and refusing before Git sees the name is an
    // Antgrid limit on top of Git's own.
    const origin = mkdtempSync(join(tmpdir(), "antgrid-branches-origin-"));
    try {
      await run(origin, ["init"]);
      await run(origin, ["config", "user.email", "test@antgrid.local"]);
      await run(origin, ["config", "user.name", "Test"]);
      writeFileSync(join(origin, "init.txt"), "seed");
      await run(origin, ["add", "."]);
      await run(origin, ["commit", "-m", "initial"]);
      await run(origin, ["branch", "remote-only"]);

      rmSync(dir, { recursive: true, force: true });
      await run(tmpdir(), ["clone", origin, dir]);
      expect((await listLocalBranches(dir)).branches).not.toContain("remote-only");

      expect(await checkoutLocalBranch(dir, "remote-only")).toEqual({ current: "remote-only" });
    } finally {
      rmSync(origin, { recursive: true, force: true });
    }
  });

  it("throws DIRTY_WORKTREE, naming the file, on conflicting uncommitted changes", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "file.txt"), "master content\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    await run(dir, ["checkout", "-b", "dev"]);
    writeFileSync(join(dir, "file.txt"), "dev content\n");
    await run(dir, ["commit", "-am", "dev commit"]);

    const catalog = await listLocalBranches(dir);
    const initialBranch = catalog.branches.find((b) => b !== "dev")!;
    await run(dir, ["checkout", initialBranch]);

    // Create uncommitted change that conflicts with dev's commit
    writeFileSync(join(dir, "file.txt"), "conflicting uncommitted content\n");

    try {
      await checkoutLocalBranch(dir, "dev");
      expect(true).toBe(false);
    } catch (err: any) {
      expect(err).toBeInstanceOf(GitHelperError);
      expect(err.code).toBe("DIRTY_WORKTREE");
      expect(err.message).toContain("file.txt");
      expect(err.message).toContain("dev");
    }

    // Verify uncommitted content remains intact
    const content = Bun.file(join(dir, "file.txt"));
    expect(await content.text()).toBe("conflicting uncommitted content\n");
  });

  it("stashes conflicting uncommitted changes and switches when stashIfDirty is set", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    // Otherwise a Windows machine's global core.autocrlf rewrites LF -> CRLF
    // on checkout, and the content assertions below would be testing git's
    // line-ending conversion instead of the stash-and-retry logic.
    await run(dir, ["config", "core.autocrlf", "false"]);
    writeFileSync(join(dir, "file.txt"), "master content\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    await run(dir, ["checkout", "-b", "dev"]);
    writeFileSync(join(dir, "file.txt"), "dev content\n");
    await run(dir, ["commit", "-am", "dev commit"]);

    const catalog = await listLocalBranches(dir);
    const initialBranch = catalog.branches.find((b) => b !== "dev")!;
    await run(dir, ["checkout", initialBranch]);

    writeFileSync(join(dir, "file.txt"), "conflicting uncommitted content\n");
    writeFileSync(join(dir, "untracked.txt"), "untracked\n");

    const res = await checkoutLocalBranch(dir, "dev", { stashIfDirty: true });
    expect(res.current).toBe("dev");
    expect(res.stashed).toBeDefined();
    expect(res.stashed!.branch).toBe(initialBranch);

    // The switch actually landed, on dev's own committed content — the stash
    // is not silently reapplied.
    const content = await Bun.file(join(dir, "file.txt")).text();
    expect(content).toBe("dev content\n");
    expect(await Bun.file(join(dir, "untracked.txt")).exists()).toBe(false);

    const stashes = await listStashes(dir);
    expect(stashes).toHaveLength(1);
    expect(stashes[0]!.ref).toBe(res.stashed!.ref);
    expect(stashes[0]!.branch).toBe(initialBranch);
  });

  it("pops a stash back onto the branch it came from, and drops it explicitly", async () => {
    await run(dir, ["init"]);
    await run(dir, ["config", "user.email", "test@antgrid.local"]);
    await run(dir, ["config", "user.name", "Test"]);
    await run(dir, ["config", "core.autocrlf", "false"]);
    writeFileSync(join(dir, "file.txt"), "v1\n");
    await run(dir, ["add", "."]);
    await run(dir, ["commit", "-m", "initial"]);

    const initialBranch = (await listLocalBranches(dir)).current!;
    await run(dir, ["checkout", "-b", "other"]);
    writeFileSync(join(dir, "file.txt"), "other content\n");
    await run(dir, ["commit", "-am", "other commit"]);
    await run(dir, ["checkout", initialBranch]);
    writeFileSync(join(dir, "file.txt"), "dirty again\n");

    const res = await checkoutLocalBranch(dir, "other", { stashIfDirty: true });
    expect(res.stashed).toBeDefined();

    // Popping back onto the branch it was stashed FROM (not wherever HEAD
    // happens to be) is what the app's Restore action does — popping onto
    // "other" instead would 3-way merge against the wrong base and conflict.
    await run(dir, ["checkout", initialBranch]);
    await stashPop(dir, res.stashed!.ref);
    expect(await listStashes(dir)).toHaveLength(0);
    expect(await Bun.file(join(dir, "file.txt")).text()).toBe("dirty again\n");

    // Drop path: stash again, then discard it instead of restoring.
    await run(dir, ["checkout", initialBranch]);
    writeFileSync(join(dir, "file.txt"), "dirty once more\n");
    const res2 = await checkoutLocalBranch(dir, "other", { stashIfDirty: true });
    await stashDrop(dir, res2.stashed!.ref);
    expect(await listStashes(dir)).toHaveLength(0);
  });
});
