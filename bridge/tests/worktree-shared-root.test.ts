import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { projectRootName } from "../src/worktrees/checkout-names";
import { WorktreeManager } from "../src/worktrees/worktree-manager";

/** Beyond RECONCILE_GRACE_MS, so an injected clock ages every directory out of
 *  the window that protects a create in flight. */
const PAST_GRACE_MS = 120_000;

async function git(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  if (code !== 0) throw new Error(stderr);
  return stdout.trim();
}

/** Two projectIds sharing a prefix, in two folders sharing a name: the state a
 *  machine lands in permanently when `sha256(path)` happens to agree on its
 *  first bytes for a repository the user cloned twice. Forced rather than
 *  waited for — it is a 1-in-65536 draw, and it is not survivable when it
 *  lands, so the behaviour under it has to be pinned. */
const ID_A = "cafe1111111111aa";
const ID_B = "cafe2222222222bb";

describe("two projects that hash into the same worktree root", () => {
  let home: string;
  let abDir: string;
  let repoA: string;
  let repoB: string;

  async function repoNamed(parent: string): Promise<string> {
    const folder = join(home, parent, "api");
    mkdirSync(folder, { recursive: true });
    await git(folder, ["init"]);
    await git(folder, ["config", "user.email", "test@antgrid.local"]);
    await git(folder, ["config", "user.name", "Antgrid Test"]);
    writeFileSync(join(folder, "readme.txt"), "initial");
    await git(folder, ["add", "."]);
    await git(folder, ["commit", "-m", "initial"]);
    return folder;
  }

  beforeEach(async () => {
    home = mkdtempSync(join(tmpdir(), "antgrid-shared-root-"));
    abDir = mkdtempSync(join(tmpdir(), "antgrid-shared-home-"));
    repoA = await repoNamed("github");
    repoB = await repoNamed("repos");
  });
  afterEach(() => { rmSync(home, { recursive: true, force: true }); rmSync(abDir, { recursive: true, force: true }); });

  function manager(extra: ConstructorParameters<typeof WorktreeManager>[0] = {}) {
    return new WorktreeManager({
      abDir,
      resolveRepoPath: async (id) => (id === ID_A ? repoA : id === ID_B ? repoB : undefined),
      ...extra,
    });
  }

  test("the fixture really does collide", () => {
    expect(projectRootName(repoA, ID_A)).toBe(projectRootName(repoB, ID_B));
  });

  test("one project's housekeeping does not reclaim the other's checkout", async () => {
    const mine = await manager().prepareForSession({ projectId: ID_A, repoPath: repoA, sessionId: "s-a" });
    const theirs = await manager().prepareForSession({ projectId: ID_B, repoPath: repoB, sessionId: "s-b" });

    // Clean, unlisted in A's store, and old enough to sweep: indistinguishable
    // from one of A's own orphans by every test except who owns it.
    const counts = await manager({ now: () => Date.now() + PAST_GRACE_MS }).reconcile(ID_A, repoA);

    expect(counts).toMatchObject({ reclaimed: 0, foreign: 1 });
    expect(existsSync(theirs.path)).toBe(true);
    expect(existsSync(mine.path)).toBe(true);
  });

  test("forgetting one project does not delete the other's uncommitted work", async () => {
    const mine = await manager().prepareForSession({ projectId: ID_A, repoPath: repoA, sessionId: "s-a" });
    const theirs = await manager().prepareForSession({ projectId: ID_B, repoPath: repoB, sessionId: "s-b" });
    writeFileSync(join(theirs.path, "readme.txt"), "work nobody asked to lose");

    const result = await manager().reclaimForgottenProject(ID_A);

    expect(result).toMatchObject({ reclaimed: 1, stranded: 1 });
    expect(existsSync(mine.path)).toBe(false);
    expect(existsSync(theirs.path)).toBe(true);
    expect(await git(theirs.path, ["status", "--porcelain"])).toContain("readme.txt");
  });

  test("forgetting one project reclaims its own leftovers even with the folder gone", async () => {
    const mine = await manager().prepareForSession({ projectId: ID_A, repoPath: repoA, sessionId: "s-a" });
    const theirs = await manager().prepareForSession({ projectId: ID_B, repoPath: repoB, sessionId: "s-b" });
    rmSync(repoA, { recursive: true, force: true });

    // Git can be asked nothing here, so ownership comes from the `.git` pointer
    // the checkout carries — the last thing on the machine that says whose it
    // was.
    const result = await manager().reclaimForgottenProject(ID_A);

    expect(result).toMatchObject({ reclaimed: 1, stranded: 1 });
    expect(existsSync(mine.path)).toBe(false);
    expect(existsSync(theirs.path)).toBe(true);
  });

  test("neither project's create is blocked by the other's directories", async () => {
    await manager().prepareForSession({ projectId: ID_B, repoPath: repoB, sessionId: "s-b" });
    const mine = await manager().prepareForSession({ projectId: ID_A, repoPath: repoA, sessionId: "s-a" });
    expect(existsSync(mine.path)).toBe(true);
  });
});
