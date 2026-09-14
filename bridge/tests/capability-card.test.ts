import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  MAX_CAPABILITY_CARD_PROJECTS,
  inProbePool,
  normalizeRemoteUrl,
  readCapabilityCard,
  readOsCard,
  readRepoCard,
} from "../src/capability-card";

async function run(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  await proc.exited;
}

let repoDir: string;
let plainDir: string;

beforeEach(async () => {
  repoDir = mkdtempSync(join(tmpdir(), "antgrid-card-repo-"));
  plainDir = mkdtempSync(join(tmpdir(), "antgrid-card-plain-"));
  await run(repoDir, ["init", "-b", "main"]);
  await run(repoDir, ["config", "user.email", "test@antgrid.local"]);
  await run(repoDir, ["config", "user.name", "Test"]);
  writeFileSync(join(repoDir, "init.txt"), "v1\n");
  await run(repoDir, ["add", "."]);
  await run(repoDir, ["commit", "-m", "initial"]);
});

afterEach(() => {
  rmSync(repoDir, { recursive: true, force: true });
  rmSync(plainDir, { recursive: true, force: true });
});

test("normalizeRemoteUrl reduces every transport to the same match key", () => {
  const same = [
    "https://github.com/Owner/Repo.git",
    "https://github.com/owner/repo",
    "https://github.com/owner/repo/",
    "http://github.com/owner/repo.git",
    "git@github.com:Owner/Repo.git",
    "git://github.com/owner/repo.git",
    "ssh://git@github.com:22/owner/repo",
    "ssh://git@github.com/owner/repo.git",
    "git+ssh://git@github.com/owner/repo.git",
    "  https://github.com/owner/repo.git  ",
  ];
  for (const url of same) {
    expect(normalizeRemoteUrl(url)).toBe("github.com/owner/repo");
  }
});

test("normalizeRemoteUrl strips embedded credentials", () => {
  const key = normalizeRemoteUrl("https://x-access-token:ghp_secrettoken@github.com/owner/repo.git");
  expect(key).toBe("github.com/owner/repo");
  expect(key).not.toContain("ghp_secrettoken");
  expect(key).not.toContain("@");
  expect(normalizeRemoteUrl("ssh://user:token@github.com:22/owner/repo")).toBe("github.com/owner/repo");
});

test("normalizeRemoteUrl keeps a non-default port in the key", () => {
  expect(normalizeRemoteUrl("ssh://git@example.com:2222/o/r.git")).toBe("example.com:2222/o/r");
  expect(normalizeRemoteUrl("https://example.com:443/o/r.git")).toBe("example.com/o/r");
  expect(normalizeRemoteUrl("http://example.com:80/o/r")).toBe("example.com/o/r");
});

test("normalizeRemoteUrl refuses anything that cannot name a repo on another machine", () => {
  for (const url of [
    "/srv/git/repo.git",
    "./repo",
    "../repo",
    "~/repos/x",
    "C:\\repos\\x",
    "c:/repos/x",
    "\\\\server\\share\\repo",
    "file:///srv/git/repo.git",
    "https://github.com/",
    "",
    "   ",
  ]) {
    expect(normalizeRemoteUrl(url)).toBeNull();
  }
});

test("readRepoCard reads origin and the branch, and the branch stays fresh", async () => {
  await run(repoDir, ["remote", "add", "origin", "https://github.com/Owner/Repo.git"]);

  const first = await readRepoCard(repoDir, "repo");
  expect(first.label).toBe("repo");
  expect(first.remote).toBe("github.com/owner/repo");
  expect(first.branch).toBe("main");

  await run(repoDir, ["checkout", "-b", "other"]);

  // No cache flush: the branch is read on every call, which is the whole
  // invalidate-on-checkout story.
  const second = await readRepoCard(repoDir, "repo");
  expect(second.branch).toBe("other");
  expect(second.remote).toBe("github.com/owner/repo");
});

test("readRepoCard answers without throwing for a repo with no origin and for a non-repo", async () => {
  const noOrigin = await readRepoCard(repoDir);
  expect(noOrigin.remote).toBeNull();
  expect(noOrigin.branch).toBe("main");
  expect("label" in noOrigin).toBe(false);

  const nonRepo = await readRepoCard(plainDir);
  expect(nonRepo.remote).toBeNull();
  expect(nonRepo.branch).toBeNull();
});

test("readRepoCard reports no branch on a detached HEAD", async () => {
  await run(repoDir, ["checkout", "--detach", "HEAD"]);
  const card = await readRepoCard(repoDir);
  expect(card.branch).toBeNull();
});

test("readOsCard describes this machine and maps the platform to a display name", () => {
  const card = readOsCard();
  expect(card.name.length).toBeGreaterThan(0);
  expect(card.version.length).toBeGreaterThan(0);
  expect(card.arch.length).toBeGreaterThan(0);
  expect(card.arch).toBe(process.arch);
  const expected = { win32: "Windows", darwin: "macOS", linux: "Linux" } as Record<string, string>;
  expect(card.name).toBe(expected[process.platform] ?? process.platform);
});

test("readCapabilityCard answers every requested project in one card", async () => {
  await run(repoDir, ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]);

  const card = await readCapabilityCard([
    { projectId: "p1", path: repoDir, label: "repo" },
    { projectId: "p2", path: plainDir, label: "plain" },
  ]);

  expect(card.os).toEqual(readOsCard());
  expect(Object.keys(card.projects).sort()).toEqual(["p1", "p2"]);
  expect(card.projects.p1).toEqual({ label: "repo", remote: "github.com/owner/repo", branch: "main" });
  expect(card.projects.p2).toEqual({ label: "plain", remote: null, branch: null });
});

test("the probe pool stays narrow however many projects it is handed", async () => {
  // Each project costs up to two git spawns and this runs beside live PTY I/O,
  // so a fan-out that scales with the catalog starves the terminals and times
  // its own probes out into a card reporting "no repo" for repos that have one.
  let inFlight = 0;
  let peak = 0;
  const done: number[] = [];
  await inProbePool([...Array(200).keys()], async (i) => {
    inFlight++;
    peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 1));
    inFlight--;
    done.push(i);
  });

  expect(done).toHaveLength(200);
  expect(peak).toBeGreaterThan(1);
  expect(peak).toBeLessThanOrEqual(8);
});

test("readCapabilityCard answers for at most MAX_CAPABILITY_CARD_PROJECTS targets", async () => {
  // The whole-catalog default has no id list to bound it — `seenProjects` only
  // ever grows, since nothing prunes a project the machine has opened once — so
  // the cap has to hold here too, not only in the request schema.
  const targets = Array.from({ length: MAX_CAPABILITY_CARD_PROJECTS + 10 }, (_, i) => ({
    projectId: `p${i}`,
    path: plainDir,
  }));

  const card = await readCapabilityCard(targets);

  expect(Object.keys(card.projects)).toHaveLength(MAX_CAPABILITY_CARD_PROJECTS);
  expect(card.projects[`p${MAX_CAPABILITY_CARD_PROJECTS}`]).toBeUndefined();
}, 30_000);
