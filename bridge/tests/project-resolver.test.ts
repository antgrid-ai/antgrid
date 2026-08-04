import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { computeProjectId } from "../src/project-id";
import { resolveProject, runGit } from "../src/worktrees/project-resolver";

async function git(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [exitCode, stdout, stderr] = await Promise.all([
    proc.exited,
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  if (exitCode !== 0) throw new Error(stderr);
  return stdout.trim();
}

describe("resolveProject", () => {
  let dir: string;

  beforeEach(() => { dir = mkdtempSync(join(tmpdir(), "antgrid-project-resolver-")); });
  afterEach(() => { rmSync(dir, { recursive: true, force: true }); });

  test("preserves the existing primary-checkout project id", async () => {
    await git(dir, ["init"]);
    const resolved = await resolveProject(dir);
    expect(resolved).toMatchObject({
      projectId: computeProjectId(dir), repoPath: dir, selectedPath: dir, isGitRepository: true,
    });
  });

  test("maps a linked worktree to its primary checkout identity", async () => {
    await git(dir, ["init"]);
    await git(dir, ["config", "user.email", "test@antgrid.local"]);
    await git(dir, ["config", "user.name", "Test"]);
    writeFileSync(join(dir, "initial.txt"), "initial\n");
    await git(dir, ["add", "."]);
    await git(dir, ["commit", "-m", "initial"]);
    const linked = join(dir, "linked checkout");
    await git(dir, ["worktree", "add", "-b", "linked", linked]);

    const [main, secondary] = await Promise.all([resolveProject(dir), resolveProject(linked)]);
    expect(secondary.projectId).toBe(main.projectId);
    expect(secondary.repoPath).toBe(main.repoPath);
    expect(secondary.selectedPath).toBe(linked);
  });

  test("keeps non-Git folders as ordinary path-hash projects", async () => {
    const resolved = await resolveProject(dir);
    expect(resolved).toEqual({
      projectId: computeProjectId(dir), repoPath: dir, selectedPath: dir, isGitRepository: false,
    });
  });

  // HostServer.open resolves before it does anything else, so a rejection here
  // takes down every project open on the machine — including for folders that
  // have nothing to do with Git.
  test("treats a Git that cannot be spawned as 'not a repository'", async () => {
    const resolved = await resolveProject(dir, async () => {
      throw new Error(`Executable not found in $PATH: "git"`);
    });
    expect(resolved.isGitRepository).toBe(false);
    expect(resolved.projectId).toBe(computeProjectId(dir));
  });

  test("runGit reports a spawn failure instead of throwing", async () => {
    const result = await runGit(["status"], join(dir, "does-not-exist"));
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toBe("");
  });
});
