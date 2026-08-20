import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { basename, join, relative, sep } from "node:path";
import { tmpdir } from "node:os";
import { CheckoutStore } from "../src/worktrees/checkout-store";
import { WorktreeError, WorktreeManager } from "../src/worktrees/worktree-manager";
import { __setRootForTest } from "../src/logger";

async function git(cwd: string, args: string[]): Promise<string> {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const [code, stdout, stderr] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  if (code !== 0) throw new Error(stderr);
  return stdout.trim();
}

describe("WorktreeManager", () => {
  let repo: string;
  let abDir: string;
  let projectId: string;
  let serial: number;

  beforeEach(async () => {
    repo = mkdtempSync(join(tmpdir(), "antgrid-worktree-repo-"));
    abDir = mkdtempSync(join(tmpdir(), "antgrid-worktree-home-"));
    projectId = "project-test";
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
      ...extra,
    });
  }

  test("creates from an explicit local branch and stores a verified checkout", async () => {
    await git(repo, ["branch", "base"]);
    const result = await manager().prepareForSession({ projectId, repoPath: repo, sessionId: "123456789", sessionName: "My feature", baseBranch: "base" });
    expect(result).toMatchObject({ kind: "managed-worktree", baseRef: "base", sessionId: "123456789" });
    // Name first for reading, then the word pair the checkout directory carries
    // — the two names have to be greppable to each other.
    expect(result.branch).toBe(`antgrid/my-feature-${basename(result.path).split("-").slice(0, 2).join("-")}`);
    expect(existsSync(result.path)).toBe(true);
    expect(await git(result.path, ["rev-parse", "--abbrev-ref", "HEAD"])).toBe(result.branch!);
    expect((await new CheckoutStore(abDir, projectId).get(result.id))?.path).toBe(result.path);
  });

  test("spends few enough path characters to leave a Windows repo room", async () => {
    // The default id generator, not the injected one: a managed checkout's path
    // is a PREFIX to every file the agent will ever touch inside it, and
    // Windows still resolves most APIs against a 260-char MAX_PATH. The
    // readable segments are capped so this bound holds however long the
    // repository folder and the session name are.
    const result = await manager({ newCheckoutId: undefined }).prepareForSession({
      projectId, repoPath: repo, sessionId: "abcdefgh",
      sessionName: "A session named at considerable and unreasonable length",
    });
    expect(result.id).toMatch(/^[0-9a-f]{10}$/);
    expect(relative(abDir, result.path).length).toBeLessThanOrEqual(45);
  });

  test("names both path segments for a human reading them", async () => {
    // The path is what shows up in a shell prompt, a terminal title and
    // `git worktree list` — an opaque hash in both segments made every isolated
    // session look the same.
    const result = await manager({ newCheckoutId: undefined })
      .prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh", sessionName: "Fix auth" });
    const [root, leaf] = relative(abDir, result.path).split(sep).slice(1);
    expect(root).toBe(`${basename(repo).slice(0, 16)}-proj`);
    expect(leaf).toMatch(/^[a-z]+-[a-z]+-[0-9a-f]{4}$/);
  });

  test("gives one session the same words every time and two sessions different ones", async () => {
    // Seeded from the session, so a directory a user has learned to recognise
    // survives a bridge restart; the checkout tail is what separates two
    // sessions that seeded the same.
    const instance = manager();
    const one = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "seed-one" });
    await instance.remove({ checkoutId: one.id, force: true, deleteBranch: true });
    const again = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "seed-one" });
    const other = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "seed-two" });

    const words = (path: string) => basename(path).split("-").slice(0, 2).join("-");
    expect(words(again.path)).toBe(words(one.path));
    expect(words(other.path)).not.toBe(words(one.path));
  });

  test("uses the main checkout HEAD when no base branch is selected", async () => {
    const expected = await git(repo, ["rev-parse", "HEAD"]);
    const result = await manager().prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    expect(result.baseRef).toBeNull();
    expect(await git(result.path, ["rev-parse", "HEAD"])).toBe(expected);
  });

  test("rejects an unknown explicit base branch before creating a checkout", async () => {
    await expect(manager().prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh", baseBranch: "missing" }))
      .rejects.toMatchObject({ code: "UNKNOWN_BASE_BRANCH" } satisfies Partial<WorktreeError>);
    expect(await new CheckoutStore(abDir, projectId).list()).toEqual([]);
  });

  test("serializes concurrent creates and avoids branch-name collisions", async () => {
    const instance = manager();
    const [one, two] = await Promise.all([
      instance.prepareForSession({ projectId, repoPath: repo, sessionId: "same-id", sessionName: "Session" }),
      instance.prepareForSession({ projectId, repoPath: repo, sessionId: "same-id", sessionName: "Session" }),
    ]);
    expect(one.branch).not.toBe(two.branch);
    expect([one.branch, two.branch].sort()).toEqual([one.branch!, `${one.branch}-2`].sort());
  });

  test("survives a session name Git would refuse as a ref", async () => {
    // `..` is invalid in a ref and no suffix can ever fix it, so deciding
    // validity inside the uniqueness loop meant 9999 git spawns — minutes, under
    // the project lock — before failing outright.
    const started = Date.now();
    const result = await manager()
      .prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh", sessionName: "v1..2" });
    expect(result.branch).toBe(`antgrid/v1-2-${basename(result.path).split("-").slice(0, 2).join("-")}`);
    expect(Date.now() - started).toBeLessThan(10_000);
  });

  test("falls back to the word pair when a name transliterates to nothing", async () => {
    const result = await manager()
      .prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh", sessionName: "プロジェクト" });
    expect(result.branch).toBe(`antgrid/${basename(result.path).split("-").slice(0, 2).join("-")}`);
  });

  test("rolls back only its own worktree and branch when metadata persistence fails", async () => {
    const brokenStore = { put: async () => { throw new Error("disk full"); } } as unknown as CheckoutStore;
    const instance = manager({ checkoutStore: () => brokenStore });
    await expect(instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" })).rejects.toMatchObject({ code: "WORKTREE_CREATE_FAILED" });
    expect((await git(repo, ["branch", "--list", "antgrid/*"]))).toBe("");
    expect((await git(repo, ["worktree", "list", "--porcelain"])).match(/^worktree /gm)?.length).toBe(1);
  });

  test("blocks dirty deletion unless force was explicitly requested and preserves branch by default", async () => {
    const instance = manager();
    const result = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    writeFileSync(join(result.path, "readme.txt"), "dirty\n");
    await expect(instance.remove({ checkoutId: result.id, force: false, deleteBranch: false })).rejects.toMatchObject({ code: "WORKTREE_DIRTY" });
    await instance.remove({ checkoutId: result.id, force: true, deleteBranch: false });
    expect(await git(repo, ["branch", "--list", result.branch!])).toBe(result.branch!);
    expect(await new CheckoutStore(abDir, projectId).get(result.id)).toBeUndefined();
  });

  test("reports unpushed commits separately from a dirty tree", async () => {
    const instance = manager();
    const result = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    writeFileSync(join(result.path, "readme.txt"), "committed in the worktree\n");
    await git(result.path, ["add", "."]);
    await git(result.path, ["commit", "-m", "work"]);

    // Clean tree, but the branch carries commits that exist nowhere else: the
    // dialog must offer to keep the branch rather than warn about lost edits.
    await expect(instance.remove({ checkoutId: result.id, force: false, deleteBranch: false }))
      .rejects.toMatchObject({ code: "WORKTREE_UNPUSHED" });
    await instance.remove({ checkoutId: result.id, force: true, deleteBranch: false });
    expect(await git(repo, ["branch", "--list", result.branch!])).toBe(result.branch!);
  });

  test("emits lifecycle events without branch names or paths", async () => {
    const lines: string[] = [];
    __setRootForTest({ write: (msg: string) => { lines.push(msg); } });
    try {
      const instance = manager();
      const result = await instance.prepareForSession({
        projectId, repoPath: repo, sessionId: "abcdefgh", sessionName: "My feature",
      });
      await instance.remove({ checkoutId: result.id, force: false, deleteBranch: false });

      const events = lines
        .map((line) => JSON.parse(line) as Record<string, unknown>)
        .filter((entry) => typeof entry.event === "string" && String(entry.event).startsWith("worktree_"));
      expect(events.map((e) => e.event)).toEqual([
        "worktree_create_started",
        "worktree_create_succeeded",
        "worktree_delete_started",
        "worktree_delete_succeeded",
      ]);
      expect(events[1]).toMatchObject({ projectId, sessionId: "abcdefgh", checkoutId: result.id });
      expect(typeof events[1].elapsedMs).toBe("number");
      const rendered = JSON.stringify(events);
      expect(rendered).not.toContain(result.branch!);
      expect(rendered).not.toContain("my-feature");
      expect(rendered).not.toContain(abDir);
    } finally {
      __setRootForTest(process.stdout);
    }
  });

  test("reports a blocked delete distinctly from a failed one", async () => {
    const lines: string[] = [];
    const instance = manager();
    const result = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    writeFileSync(join(result.path, "readme.txt"), "dirty\n");
    __setRootForTest({ write: (msg: string) => { lines.push(msg); } });
    try {
      await expect(instance.remove({ checkoutId: result.id, force: false, deleteBranch: false }))
        .rejects.toMatchObject({ code: "WORKTREE_DIRTY" });
    } finally {
      __setRootForTest(process.stdout);
    }
    const events = lines.map((line) => JSON.parse(line) as Record<string, unknown>);
    expect(events.at(-1)).toMatchObject({
      event: "worktree_delete_blocked", checkoutId: result.id, errorCode: "WORKTREE_DIRTY",
    });
  });

  test("isolates the same relative file across two checkouts and restores metadata after restart", async () => {
    const firstProcess = manager();
    const [one, two] = await Promise.all([
      firstProcess.prepareForSession({ projectId, repoPath: repo, sessionId: "session-one", sessionName: "One" }),
      firstProcess.prepareForSession({ projectId, repoPath: repo, sessionId: "session-two", sessionName: "Two" }),
    ]);
    writeFileSync(join(one.path, "readme.txt"), "one\n");
    writeFileSync(join(two.path, "readme.txt"), "two\n");
    expect(readFileSync(join(repo, "readme.txt"), "utf8")).toBe("initial\n");
    expect(readFileSync(join(one.path, "readme.txt"), "utf8")).toBe("one\n");
    expect(readFileSync(join(two.path, "readme.txt"), "utf8")).toBe("two\n");

    const restarted = new WorktreeManager({
      abDir,
      resolveRepoPath: async (id) => id === projectId ? repo : undefined,
    });
    expect(await restarted.inspect(one.id)).toMatchObject({ exists: true, registered: true, dirty: true });
    expect(await restarted.inspect(two.id)).toMatchObject({ exists: true, registered: true, dirty: true });
    await restarted.remove({ checkoutId: one.id, force: true, deleteBranch: false });
    await restarted.remove({ checkoutId: two.id, force: true, deleteBranch: false });
  });

  test("reports missing and locked worktrees without auto-unlocking", async () => {
    const instance = manager();
    const result = await instance.prepareForSession({ projectId, repoPath: repo, sessionId: "abcdefgh" });
    await git(repo, ["worktree", "lock", result.path]);
    expect((await instance.inspect(result.id)).locked).toBe(true);
    await expect(instance.remove({ checkoutId: result.id, force: false, deleteBranch: false })).rejects.toMatchObject({ code: "WORKTREE_CONFLICT" });
    rmSync(result.path, { recursive: true, force: true });
    expect((await instance.inspect(result.id)).exists).toBe(false);
  });
});
