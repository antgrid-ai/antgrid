import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import { WorktreeManager } from "../src/worktrees/worktree-manager";

/** Beyond RECONCILE_GRACE_MS, so an injected clock puts every existing
 *  directory's mtime outside the window that protects a create in flight. */
const PAST_GRACE_MS = 120_000;

async function git(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  if (code !== 0) throw new Error(stderr);
  return stdout.trim();
}

describe("WorktreeManager reconciliation", () => {
  let repo: string;
  let abDir: string;
  let projectId: string;
  let serial: number;

  beforeEach(async () => {
    repo = mkdtempSync(join(tmpdir(), "antgrid-reconcile-repo-"));
    abDir = mkdtempSync(join(tmpdir(), "antgrid-reconcile-home-"));
    projectId = "project-reconcile";
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

  /** A clock far enough ahead that every already-created directory looks old. */
  function agedManager(extra: ConstructorParameters<typeof WorktreeManager>[0] = {}) {
    return manager({ now: () => Date.now() + PAST_GRACE_MS, ...extra });
  }

  test("prunes a row whose directory vanished and leaves a healthy sibling alone", async () => {
    const instance = manager();
    const gone = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one", sessionName: "One" });
    const kept = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-two", sessionName: "Two" });
    rmSync(gone.path, { recursive: true, force: true });

    expect(await instance.reconcile(projectId, repo)).toMatchObject({ pruned: 1, reclaimed: 0 });

    // A row without a directory is worse than cosmetic: the registration
    // survives it, so `remove()` can neither find the directory nor let Git drop
    // it, and the owning session becomes permanently undeletable.
    const store = new CheckoutStore(abDir, projectId);
    expect((await store.list()).map((record) => record.id)).toEqual([kept.id]);
    expect(existsSync(kept.path)).toBe(true);
  });

  test("reclaims a directory under the project's worktree root that no row names", async () => {
    const instance = manager();
    const orphan = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    await new CheckoutStore(abDir, projectId).remove(orphan.id);

    expect(await agedManager().reconcile(projectId, repo)).toMatchObject({ pruned: 0, reclaimed: 1 });

    expect(existsSync(orphan.path)).toBe(false);
    expect((await git(repo, ["worktree", "list", "--porcelain"])).match(/^worktree /gm)?.length).toBe(1);
  });

  test("leaves an orphan directory alone while it is inside the grace window", async () => {
    const instance = manager();
    const orphan = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    await new CheckoutStore(abDir, projectId).remove(orphan.id);

    // The project lock is per-process, so a second bridge sharing this
    // ANTGRID_DIR could be creating this very directory right now. A freshly
    // touched candidate is never reclaimed; a too-short window only defers.
    expect(await instance.reconcile(projectId, repo)).toMatchObject({ pruned: 0, reclaimed: 0 });
    expect(existsSync(orphan.path)).toBe(true);
  });

  test("a create after a hand-deleted worktree leaves no stale row or registration", async () => {
    const instance = manager();
    const gone = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one" });
    rmSync(gone.path, { recursive: true, force: true });

    // Reconciliation runs inside the create lock, so this is the one path that
    // pays for it — and its failure modes must never fail the create.
    const fresh = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-two" });

    expect(existsSync(fresh.path)).toBe(true);
    const store = new CheckoutStore(abDir, projectId);
    expect((await store.list()).map((record) => record.id)).toEqual([fresh.id]);
    const listed = (await git(repo, ["worktree", "list", "--porcelain"])).match(/^worktree /gm)?.length;
    expect(listed).toBe(2); // main + the fresh checkout
  });

  test("a reconciliation that cannot read the store still lets the create through", async () => {
    // Housekeeping rides on the create path because that is the one moment
    // already holding the lock and the repository — so it must never be able to
    // fail the thing the user actually asked for.
    const broken = {
      read: async () => { throw new Error("checkouts.json unreadable"); },
      list: async () => { throw new Error("checkouts.json unreadable"); },
      put: async () => {},
      get: async () => undefined,
      remove: async () => false,
    } as unknown as CheckoutStore;
    const checkout = await manager({ checkoutStore: () => broken })
      .prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    expect(existsSync(checkout.path)).toBe(true);
  });

  test("reclaims nothing while the store carries a row it cannot parse", async () => {
    // "Not in the list" is only evidence of an orphan when the list is complete.
    // CheckoutStore drops a bad row on purpose so it cannot hide its healthy
    // siblings — reading that as "nothing names this directory" turns the
    // tolerance into a force-delete of a live checkout's uncommitted work.
    const instance = manager();
    const live = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    writeFileSync(join(live.path, "in-flight.txt"), "unsaved\n");
    const file = join(abDir, "agents", projectId, "checkouts.json");
    const contents = JSON.parse(await Bun.file(file).text());
    contents.checkouts[0].createdAt = "not-a-number";
    writeFileSync(file, JSON.stringify(contents));

    expect(await agedManager().reconcile(projectId, repo)).toMatchObject({ reclaimed: 0 });
    expect(existsSync(live.path)).toBe(true);
    expect(existsSync(join(live.path, "in-flight.txt"))).toBe(true);
  });

  test("reclaims nothing while the store file itself is unreadable", async () => {
    const instance = manager();
    const live = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    writeFileSync(join(abDir, "agents", projectId, "checkouts.json"), "{ truncated");

    expect(await agedManager().reconcile(projectId, repo)).toMatchObject({ reclaimed: 0 });
    expect(existsSync(live.path)).toBe(true);
  });

  test("leaves an unreferenced directory alone once something has worked in it", async () => {
    // Housekeeping rides on a create the user asked for, so it must be at least
    // as reluctant as the explicit delete, which refuses WORKTREE_DIRTY.
    const instance = manager();
    const orphan = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    await new CheckoutStore(abDir, projectId).remove(orphan.id);
    writeFileSync(join(orphan.path, "readme.txt"), "edited\n");

    expect(await agedManager().reconcile(projectId, repo)).toMatchObject({ reclaimed: 0 });
    expect(existsSync(orphan.path)).toBe(true);
  });

  test("prunes rows without a repository and never throws", async () => {
    const instance = manager();
    const gone = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    rmSync(gone.path, { recursive: true, force: true });
    mkdirSync(join(abDir, "wt", projectId, "stray"), { recursive: true });

    // Housekeeping on the side of work the caller actually asked for: with no
    // repository to ask, the rows are still ours to correct.
    expect(await manager({ resolveRepoPath: undefined }).reconcile(projectId))
      .toMatchObject({ pruned: 1 });
    expect(await new CheckoutStore(abDir, projectId).list()).toEqual([]);
  });
});
