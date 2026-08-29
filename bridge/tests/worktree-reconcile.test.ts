import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { __setRootForTest } from "../src/logger";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import { WorktreeManager, type ReconcileCounts } from "../src/worktrees/worktree-manager";

/** Beyond RECONCILE_GRACE_MS, so an injected clock puts every existing
 *  directory's mtime outside the window that protects a create in flight. */
const PAST_GRACE_MS = 120_000;

/** Make a directory survive a recursive delete, and return the release.
 *
 *  Windows is held the way the field failure holds it — the directory is a live
 *  process's current directory, which Windows refuses to delete and which is
 *  the entire bug. POSIX has no such rule, so a parent nothing may write to
 *  stands in for it: the sweep's reporting is what these tests are about, not
 *  the mechanism that refused. */
function holdDirectory(dir: string): () => void {
  if (process.platform === "win32") {
    const previous = process.cwd();
    process.chdir(dir);
    return () => { process.chdir(previous); };
  }
  const parent = dirname(dir);
  chmodSync(parent, 0o500);
  return () => { chmodSync(parent, 0o700); };
}

/** Whether this environment enforces [holdDirectory] at all — root ignores the
 *  POSIX half, and CI containers commonly run as root. */
const HOLD_ENFORCED = ((): boolean => {
  const probe = mkdtempSync(join(tmpdir(), "antgrid-hold-probe-"));
  const dir = join(probe, "held");
  mkdirSync(dir);
  const release = holdDirectory(dir);
  try { rmSync(dir, { recursive: true, force: true }); } catch { /* refused outright, which is the answer */ }
  const enforced = existsSync(dir);
  release();
  rmSync(probe, { recursive: true, force: true });
  return enforced;
})();

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

  test.skipIf(!HOLD_ENFORCED)("reports a reclaim that left its directory standing, and who held it", async () => {
    const instance = manager();
    const orphan = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    await new CheckoutStore(abDir, projectId).remove(orphan.id);

    const lines: string[] = [];
    let counts: ReconcileCounts | undefined;
    const release = holdDirectory(orphan.path);
    __setRootForTest({ write: (message: string) => { lines.push(message); } }, "info");
    try {
      counts = await agedManager({
        // The real enumeration reads this machine's entire process table:
        // right on a failure path, wrong in a test that would then assert on
        // whatever else happens to be running.
        listHolders: () => [{ pid: 4242, name: "bun.exe", cwd: join(orphan.path, "bridge") }],
      }).reconcile(projectId, repo);
    } finally {
      __setRootForTest(process.stdout, "info");
      release();
    }

    // The defect this event exists for: both calls in the sweep swallow their
    // failure and a survivor moves no count, so `worktree_reconcile_completed`
    // reads exactly like a sweep with nothing to do — on every create, for as
    // long as the directory stays stranded.
    expect(counts).toMatchObject({ reclaimed: 0 });
    expect(existsSync(orphan.path)).toBe(true);
    expect(lines.join("")).toContain("worktree_reclaim_failed");
    expect(lines.join("")).toContain("bun.exe");
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
  /** The wreckage a `worktree remove` leaves when it dies partway: Git deletes
   *  the `.git` link early in its sweep, aborts on a directory something holds
   *  open, and a later prune reaps the registration the link pointed at. */
  async function strandCheckout(path: string): Promise<void> {
    rmSync(join(path, ".git"), { force: true });
    await git(repo, ["worktree", "prune"]);
  }

  test("reclaims a checkout Git no longer registers and whose `.git` link is gone", async () => {
    const instance = manager();
    const stranded = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one", sessionName: "One" });
    const kept = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-two", sessionName: "Two" });
    await strandCheckout(stranded.path);

    // Counted as live before this arm existed, purely because the directory was
    // still there — which left its session deletable by no route at all.
    expect(await agedManager().reconcile(projectId, repo)).toMatchObject({ pruned: 1, reclaimed: 1 });

    expect(existsSync(stranded.path)).toBe(false);
    expect((await new CheckoutStore(abDir, projectId).list()).map((record) => record.id)).toEqual([kept.id]);
    expect(existsSync(kept.path)).toBe(true);
  });

  test("leaves an unregistered checkout alone while it still has a `.git` link", async () => {
    // Both signals are required. A directory that still claims a Git checkout
    // may hold work, whatever the repository's registration says about it.
    const instance = manager();
    const checkout = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one" });
    rmSync(join(repo, ".git", "worktrees"), { recursive: true, force: true });

    expect(await agedManager().reconcile(projectId, repo)).toMatchObject({ pruned: 0, reclaimed: 0 });

    expect(existsSync(checkout.path)).toBe(true);
    expect((await new CheckoutStore(abDir, projectId).list()).map((record) => record.id)).toEqual([checkout.id]);
  });

  test("treats every checkout as live when Git cannot be asked at all", async () => {
    // An empty listing and an unanswered question look identical, and only one
    // of them means the checkouts are gone.
    const instance = manager();
    const checkout = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one" });
    await strandCheckout(checkout.path);
    const failing = agedManager({ git: async () => ({ exitCode: 128, stdout: "", stderr: "not a repository" }) });

    expect(await failing.reconcile(projectId, repo)).toMatchObject({ pruned: 0, reclaimed: 0 });

    expect(existsSync(checkout.path)).toBe(true);
    expect((await new CheckoutStore(abDir, projectId).list()).map((record) => record.id)).toEqual([checkout.id]);
  });
});
