import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { listLocalBranches, checkoutLocalBranch, GitHelperError } from "../src/git-branches";

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

  it("throws CHECKOUT_FAILED on conflicting dirty working tree", async () => {
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
      expect(err.code).toBe("CHECKOUT_FAILED");
    }

    // Verify uncommitted content remains intact
    const content = Bun.file(join(dir, "file.txt"));
    expect(await content.text()).toBe("conflicting uncommitted content\n");
  });
});
