import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import { WorktreeManager } from "../src/worktrees/worktree-manager";

async function git(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  if (code !== 0) throw new Error(stderr);
  return stdout.trim();
}

describe("WorktreeManager.reclaimForgottenProject", () => {
  let repo: string;
  let abDir: string;
  let projectId: string;
  let serial: number;

  beforeEach(async () => {
    repo = mkdtempSync(join(tmpdir(), "antgrid-reclaim-repo-"));
    abDir = mkdtempSync(join(tmpdir(), "antgrid-reclaim-home-"));
    projectId = "project-reclaim";
    serial = 0;
    await git(repo, ["init"]);
    await git(repo, ["config", "user.email", "test@antgrid.local"]);
    await git(repo, ["config", "user.name", "Antgrid Test"]);
    writeFileSync(join(repo, "readme.txt"), "initial\n");
    await git(repo, ["add", "."]);
    await git(repo, ["commit", "-m", "initial"]);
  });
  afterEach(() => { rmSync(repo, { recursive: true, force: true }); rmSync(abDir, { recursive: true, force: true }); });

  function manager(extra: ConstructorParameters<typeof WorktreeManager>[0] = {}) {
    return new WorktreeManager({
      abDir,
      newCheckoutId: () => `checkout-${++serial}`,
      resolveRepoPath: async (id) => id === projectId ? repo : undefined,
      ...extra,
    });
  }

  function worktreeRoot(): string {
    return join(abDir, "wt", projectId);
  }

  test("removes every managed worktree and its registration while keeping the branch", async () => {
    const instance = manager();
    const one = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one", sessionName: "One" });
    const two = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-two", sessionName: "Two" });

    const result = await instance.reclaimForgottenProject(projectId);

    expect(result.reclaimed).toBe(2);
    expect(result.stranded).toBe(0);
    expect(existsSync(worktreeRoot())).toBe(false);
    expect((await git(repo, ["worktree", "list", "--porcelain"])).match(/^worktree /gm)?.length).toBe(1);
    // Branches are the one thing forget() must never destroy: they carry the
    // user's commits, and deleting a project in Antgrid may not rewrite their
    // repository.
    expect((await git(repo, ["branch", "--list", "antgrid/*"])).split(/\r?\n/).length).toBe(2);
    expect(await git(repo, ["branch", "--list", one.branch!])).toContain(one.branch!);
    expect(await git(repo, ["branch", "--list", two.branch!])).toContain(two.branch!);
  });

  test("force-removes a worktree with uncommitted edits that remove() would refuse", async () => {
    const instance = manager();
    const checkout = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    writeFileSync(join(checkout.path, "readme.txt"), "dirty\n");
    await expect(instance.remove({ checkoutId: checkout.id, force: false, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_DIRTY" });

    // No refusal arm at all: the metadata that names this checkout is deleted
    // one step later regardless, so refusing would only strand the directory.
    expect(await instance.reclaimForgottenProject(projectId)).toMatchObject({ reclaimed: 1, stranded: 0 });
    expect(existsSync(checkout.path)).toBe(false);
  });

  test("reclaims the disk when the repository folder is already gone", async () => {
    const instance = manager();
    const checkout = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    rmSync(repo, { recursive: true, force: true });

    // The common reason to forget a project is that its folder went away, so
    // Git can be asked nothing and the blanket removal of our own root is the
    // only thing that reclaims the disk.
    expect(await instance.reclaimForgottenProject(projectId)).toMatchObject({ reclaimed: 1, stranded: 0 });
    expect(existsSync(checkout.path)).toBe(false);
    expect(existsSync(worktreeRoot())).toBe(false);
  });

  test("reclaims a locked worktree and leaves no registration behind", async () => {
    const instance = manager();
    const checkout = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    await git(repo, ["worktree", "lock", checkout.path]);

    // `--force` once still refuses a locked worktree, and `worktree prune` skips
    // locked entries forever — so a single force would leave a registration no
    // later prune could ever clear.
    expect(await instance.reclaimForgottenProject(projectId)).toMatchObject({ reclaimed: 1, stranded: 0 });
    expect((await git(repo, ["worktree", "list", "--porcelain"])).match(/^worktree /gm)?.length).toBe(1);
  });

  test("refuses a project id that would point the recursive delete outside the worktree root", async () => {
    const instance = manager();
    const checkout = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });

    // The id arrives from a control-plane verb, so a traversal component must
    // never reach the `rm`.
    expect(await instance.reclaimForgottenProject("../..")).toMatchObject({ reclaimed: 0, stranded: 0 });
    expect(existsSync(checkout.path)).toBe(true);
    expect(existsSync(abDir)).toBe(true);
    expect((await new CheckoutStore(abDir, projectId).list()).length).toBe(1);
  });
});
