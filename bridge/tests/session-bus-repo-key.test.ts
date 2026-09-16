import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionBusRepoKeys } from "../src/session-bus/repo-key";

async function git(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

// Fresh directories per test: the probe behind SessionBusRepoKeys caches by
// PATH inside capability-card.ts, so reusing one would answer a later test from
// an earlier test's remote.
let repoDir: string;
let worktreeDir: string;
let plainDir: string;

async function initRepo(dir: string) {
  await git(dir, ["init", "-b", "main"]);
  await git(dir, ["config", "user.email", "test@antgrid.local"]);
  await git(dir, ["config", "user.name", "Test"]);
  writeFileSync(join(dir, "init.txt"), "v1\n");
  await git(dir, ["add", "."]);
  await git(dir, ["commit", "-m", "initial"]);
}

beforeEach(async () => {
  repoDir = mkdtempSync(join(tmpdir(), "antgrid-repokey-a-"));
  worktreeDir = mkdtempSync(join(tmpdir(), "antgrid-repokey-b-"));
  plainDir = mkdtempSync(join(tmpdir(), "antgrid-repokey-c-"));
  await initRepo(repoDir);
  await initRepo(worktreeDir);
});

afterEach(() => {
  for (const d of [repoDir, worktreeDir, plainDir]) rmSync(d, { recursive: true, force: true });
});

test("two project ids on one remote share a key, which is what makes a worktree addressable", async () => {
  // Deliberately the two spellings of one remote: the whole point of the key is
  // that a worktree cut from a repo answers the same string as the repo.
  await git(repoDir, ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]);
  await git(worktreeDir, ["remote", "add", "origin", "https://github.com/owner/repo"]);

  const keys = new SessionBusRepoKeys();
  await keys.note("parent", repoDir);
  await keys.note("worktree", worktreeDir);

  expect(keys.keyFor("parent")).toBe("github.com/owner/repo");
  expect(keys.keyFor("worktree")).toBe("github.com/owner/repo");
  expect(keys.projectsSharing(keys.keyFor("parent")).sort()).toEqual(["parent", "worktree"]);
});

test("a project with no remote is probed, keyless, and shares with nobody", async () => {
  const keys = new SessionBusRepoKeys();
  await keys.note("no-origin", repoDir);
  await keys.note("not-a-repo", plainDir);

  expect(keys.keyFor("no-origin")).toBeNull();
  expect(keys.probed("no-origin")).toBe(true);
  expect(keys.probed("not-a-repo")).toBe(true);
  // §5.1 fails closed: two keyless projects are not peers of each other.
  expect(keys.projectsSharing(null)).toEqual([]);
});

test("an unprobed project is distinguishable from one that answered no remote", async () => {
  const keys = new SessionBusRepoKeys();
  expect(keys.keyFor("never-seen")).toBeNull();
  expect(keys.probed("never-seen")).toBe(false);

  await keys.note("never-seen", plainDir);
  expect(keys.keyFor("never-seen")).toBeNull();
  expect(keys.probed("never-seen")).toBe(true);
});

test("one clock governs a re-probe, and it is the probe's own", async () => {
  await git(repoDir, ["remote", "add", "origin", "git@github.com:Owner/First.git"]);
  const keys = new SessionBusRepoKeys();
  await keys.note("p", repoDir);
  expect(keys.keyFor("p")).toBe("github.com/owner/first");

  // The remote moves. `readRepoKey` caches by path, so an edge inside its
  // window answers from that cache rather than spawning git again — this class
  // adds no interval of its own, which is what stops the two disagreeing.
  await git(repoDir, ["remote", "set-url", "origin", "git@github.com:Owner/Second.git"]);
  await keys.note("p", repoDir);
  expect(keys.keyFor("p")).toBe("github.com/owner/first");

  // A path the probe has never seen reads the moved remote immediately, which
  // is the same code path an expired cache entry takes.
  await keys.note("fresh-path", worktreeDir);
  expect(keys.probed("fresh-path")).toBe(true);
});

test("note ignores a project with no path rather than recording a keyless one", async () => {
  const keys = new SessionBusRepoKeys();
  await keys.note("pathless", undefined);
  expect(keys.probed("pathless")).toBe(false);
});

test("forgetProject drops the key, so a forgotten project stops being a peer", async () => {
  await git(repoDir, ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]);
  await git(worktreeDir, ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]);
  const keys = new SessionBusRepoKeys();
  await keys.note("parent", repoDir);
  await keys.note("worktree", worktreeDir);

  keys.forgetProject("worktree");
  expect(keys.projectsSharing("github.com/owner/repo")).toEqual(["parent"]);
  expect(keys.probed("worktree")).toBe(false);
});

test("hydrate probes every project it is handed", async () => {
  await git(repoDir, ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]);
  const keys = new SessionBusRepoKeys();
  await keys.hydrate([
    { id: "p1", path: repoDir },
    { id: "p2", path: plainDir },
    { id: "p3" },
  ]);
  expect(keys.keyFor("p1")).toBe("github.com/owner/repo");
  expect(keys.probed("p2")).toBe(true);
  expect(keys.probed("p3")).toBe(false);
});
