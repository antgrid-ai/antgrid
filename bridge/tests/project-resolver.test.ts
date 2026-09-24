import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { computeProjectId } from "../src/project-id";
import { projectRootName } from "../src/worktrees/checkout-names";
import { CheckoutStore } from "../src/worktrees/checkout-store";
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

// Windows tmpdir() can be a short (8.3) path, and the resolver realpath's
// everything it compares — so expectations must be canonicalised the same way
// or they compare a short spelling against a long one.
function canonical(path: string): string {
  return realpathSync.native(path);
}

async function initRepo(dir: string): Promise<void> {
  await git(dir, ["init"]);
  await git(dir, ["config", "user.email", "test@antgrid.local"]);
  await git(dir, ["config", "user.name", "Test"]);
  writeFileSync(join(dir, "initial.txt"), "initial\n");
  await git(dir, ["add", "."]);
  await git(dir, ["commit", "-m", "initial"]);
}

describe("resolveProject", () => {
  let dir: string;
  let abDir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-project-resolver-"));
    abDir = mkdtempSync(join(tmpdir(), "antgrid-project-resolver-ab-"));
  });
  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    rmSync(abDir, { recursive: true, force: true });
  });

  test("preserves the existing primary-checkout project id", async () => {
    await git(dir, ["init"]);
    const resolved = await resolveProject(dir);
    expect(resolved).toMatchObject({
      projectId: computeProjectId(dir), repoPath: dir, selectedPath: dir, isGitRepository: true, kind: "primary",
    });
  });

  test("folds a managed checkout onto its primary and reports its checkoutId", async () => {
    await initRepo(dir);
    const repoPath = canonical(dir);
    const projectId = computeProjectId(repoPath);
    const root = join(abDir, "wt", projectRootName(repoPath, projectId));
    const checkoutPath = join(root, "managed-checkout");
    await git(dir, ["worktree", "add", "-b", "managed", checkoutPath]);
    const canonicalCheckoutPath = canonical(checkoutPath);

    await new CheckoutStore(abDir, projectId).put({
      id: "checkout-1", projectId, kind: "managed-worktree", path: canonicalCheckoutPath,
      branch: "managed", baseRef: null, managed: true, sessionId: "session-1", createdAt: 0,
    });

    const resolved = await resolveProject(checkoutPath, runGit, { abDir });
    expect(resolved).toEqual({
      projectId, repoPath, selectedPath: canonicalCheckoutPath, isGitRepository: true,
      kind: "managed-checkout", checkoutId: "checkout-1", repoKey: null,
    });
  });

  test("folds a managed checkout with no store record, omitting checkoutId", async () => {
    await initRepo(dir);
    const repoPath = canonical(dir);
    const projectId = computeProjectId(repoPath);
    const root = join(abDir, "wt", projectRootName(repoPath, projectId));
    const checkoutPath = join(root, "managed-checkout");
    await git(dir, ["worktree", "add", "-b", "managed", checkoutPath]);
    const canonicalCheckoutPath = canonical(checkoutPath);

    const resolved = await resolveProject(checkoutPath, runGit, { abDir });
    expect(resolved).toStrictEqual({
      projectId, repoPath, selectedPath: canonicalCheckoutPath, isGitRepository: true,
      kind: "managed-checkout", repoKey: null,
    });
    expect("checkoutId" in resolved).toBe(false);
  });

  // An isolated session started inside a linked worktree the user opened as its
  // own project. `git worktree list` still names the primary, so folding there
  // would open a project whose store has no record of this checkout — the wrong
  // row, with nothing to focus. Observed live on 2026-09-08.
  test("folds a managed checkout onto the project that owns it, not the primary", async () => {
    await initRepo(dir);
    const linked = join(dir, "linked checkout");
    await git(dir, ["worktree", "add", "-b", "linked", linked]);
    const canonicalLinked = canonical(linked);
    const ownerId = computeProjectId(canonicalLinked);
    const root = join(abDir, "wt", projectRootName(canonicalLinked, ownerId));
    const checkoutPath = join(root, "managed-checkout");
    await git(linked, ["worktree", "add", "-b", "managed", checkoutPath]);
    const canonicalCheckoutPath = canonical(checkoutPath);

    await new CheckoutStore(abDir, ownerId).put({
      id: "checkout-2", projectId: ownerId, kind: "managed-worktree", path: canonicalCheckoutPath,
      branch: "managed", baseRef: null, managed: true, sessionId: "session-2", createdAt: 0,
    });

    const resolved = await resolveProject(checkoutPath, runGit, { abDir });
    expect(resolved).toEqual({
      projectId: ownerId, repoPath: canonicalLinked, selectedPath: canonicalCheckoutPath,
      isGitRepository: true, kind: "managed-checkout", checkoutId: "checkout-2", repoKey: null,
    });
  });

  // Every kind this resolver returns keeps projectId === computeProjectId(repoPath),
  // and HostServer.open refuses a pair that breaks it. An owner whose folder is
  // gone must therefore lose to the primary rather than name a repoPath that
  // hashes to something else.
  test("ignores an owning record whose project folder is no longer a worktree", async () => {
    await initRepo(dir);
    const repoPath = canonical(dir);
    const projectId = computeProjectId(repoPath);
    const root = join(abDir, "wt", projectRootName(repoPath, projectId));
    const checkoutPath = join(root, "managed-checkout");
    await git(dir, ["worktree", "add", "-b", "managed", checkoutPath]);
    const canonicalCheckoutPath = canonical(checkoutPath);

    const strandedId = computeProjectId(join(dir, "worktree removed since"));
    await new CheckoutStore(abDir, strandedId).put({
      id: "checkout-3", projectId: strandedId, kind: "managed-worktree", path: canonicalCheckoutPath,
      branch: "managed", baseRef: null, managed: true, sessionId: "session-3", createdAt: 0,
    });

    const resolved = await resolveProject(checkoutPath, runGit, { abDir });
    expect(resolved).toStrictEqual({
      projectId, repoPath, selectedPath: canonicalCheckoutPath, isGitRepository: true,
      kind: "managed-checkout", repoKey: null,
    });
  });

  test("gives a user-made linked worktree outside wt/ its own identity", async () => {
    await initRepo(dir);
    const linked = join(dir, "linked checkout");
    await git(dir, ["worktree", "add", "-b", "linked", linked]);
    const canonicalLinked = canonical(linked);

    const resolved = await resolveProject(linked, runGit, { abDir });
    expect(resolved).toEqual({
      projectId: computeProjectId(canonicalLinked), repoPath: canonicalLinked, selectedPath: canonicalLinked,
      isGitRepository: true, kind: "linked-worktree", repoKey: null,
    });
  });

  test("folds a plain subdirectory of the primary onto the primary, not a linked-worktree of its own", async () => {
    await initRepo(dir);
    const repoPath = canonical(dir);
    const sub = join(dir, "src");
    mkdirSync(sub);

    const resolved = await resolveProject(sub, runGit, { abDir });
    expect(resolved).toEqual({
      projectId: computeProjectId(repoPath), repoPath, selectedPath: canonical(sub),
      isGitRepository: true, kind: "primary", repoKey: null,
    });
  });

  test("folds a subdirectory of a linked worktree onto that worktree's own root", async () => {
    await initRepo(dir);
    const linked = join(dir, "linked checkout");
    await git(dir, ["worktree", "add", "-b", "linked", linked]);
    const canonicalLinked = canonical(linked);
    const sub = join(linked, "src");
    mkdirSync(sub);

    const resolved = await resolveProject(sub, runGit, { abDir });
    expect(resolved).toEqual({
      projectId: computeProjectId(canonicalLinked), repoPath: canonicalLinked, selectedPath: canonical(sub),
      isGitRepository: true, kind: "linked-worktree", repoKey: null,
    });
  });

  test("keeps non-Git folders as ordinary path-hash projects", async () => {
    const resolved = await resolveProject(dir);
    expect(resolved).toEqual({
      projectId: computeProjectId(dir), repoPath: dir, selectedPath: dir, isGitRepository: false,
      kind: "plain", repoKey: null,
    });
  });

  test("folds the origin remote into a repoKey", async () => {
    await git(dir, ["init"]);
    await git(dir, ["remote", "add", "origin", "git@github.com:antgrid/antgrid.git"]);
    const resolved = await resolveProject(dir);
    expect(resolved.repoKey).toBe("github.com/antgrid/antgrid");
  });

  test("a repository with no origin has no repoKey", async () => {
    await git(dir, ["init"]);
    const resolved = await resolveProject(dir);
    expect(resolved.isGitRepository).toBe(true);
    expect(resolved.repoKey).toBeNull();
  });

  test("a failing remote-url call leaves the resolve otherwise intact", async () => {
    await git(dir, ["init"]);
    await git(dir, ["remote", "add", "origin", "https://github.com/antgrid/antgrid.git"]);
    const resolved = await resolveProject(dir, async (args, cwd) => {
      if (args[0] === "remote") throw new Error("git remote exploded");
      return runGit(args, cwd);
    });
    expect(resolved.repoKey).toBeNull();
    expect(resolved.isGitRepository).toBe(true);
    expect(resolved.projectId).toBe(computeProjectId(dir));
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
    expect(resolved.kind).toBe("plain");
  });

  test("runGit reports a spawn failure instead of throwing", async () => {
    const result = await runGit(["status"], join(dir, "does-not-exist"));
    expect(result.exitCode).not.toBe(0);
    expect(result.stdout).toBe("");
  });
});
