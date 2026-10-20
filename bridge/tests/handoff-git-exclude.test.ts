import { afterEach, describe, expect, it } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { ensureHandoffExcluded } from "../src/handoff/git-exclude";

const ID = "11111111-2222-4333-8444-555555555555";
const dirs: string[] = [];
afterEach(() => { for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true }); });

function tmp(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "antgrid-exclude-")));
  dirs.push(dir);
  return dir;
}

function git(cwd: string, ...args: string[]): string {
  const run = Bun.spawnSync(["git", "-c", "user.name=t", "-c", "user.email=t@example.com", ...args], { cwd });
  if (run.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${run.stderr.toString()}`);
  return run.stdout.toString();
}

function repo(): string {
  const dir = tmp();
  git(dir, "init", "-q");
  writeFileSync(join(dir, "a.txt"), "a\n");
  git(dir, "add", "a.txt");
  git(dir, "commit", "-q", "-m", "init");
  return dir;
}

function dropHandoffFile(root: string): void {
  const dir = join(root, ".antgrid", "handoff", ID);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "manifest.json"), "{}");
}

describe("ensureHandoffExcluded", () => {
  it("adds the anchored pattern once and keeps git status clean", async () => {
    const dir = repo();
    expect(await ensureHandoffExcluded(dir, ID)).toBe("excluded");
    expect(await ensureHandoffExcluded(dir, ID)).toBe("excluded");
    const exclude = readFileSync(join(dir, ".git", "info", "exclude"), "utf8");
    expect(exclude.split("\n").filter((line) => line === "/.antgrid/handoff/")).toHaveLength(1);
    dropHandoffFile(dir);
    expect(git(dir, "status", "--porcelain")).toBe("");
  });

  it("writes a linked worktree's exclude into the common dir, so status is clean and removal is not refused", async () => {
    const dir = repo();
    const wt = join(tmp(), "wt");
    git(dir, "worktree", "add", "-q", "-b", "feature", wt);
    expect(await ensureHandoffExcluded(wt, ID)).toBe("excluded");
    expect(readFileSync(join(dir, ".git", "info", "exclude"), "utf8")).toContain("/.antgrid/handoff/");
    dropHandoffFile(wt);
    expect(git(wt, "status", "--porcelain")).toBe("");
    git(dir, "worktree", "remove", wt);
    expect(existsSync(wt)).toBe(false);
  });

  it("keeps CRLF and repairs a missing trailing newline", async () => {
    const dir = repo();
    writeFileSync(join(dir, ".git", "info", "exclude"), "# keep\r\nfoo");
    await ensureHandoffExcluded(dir, ID);
    expect(readFileSync(join(dir, ".git", "info", "exclude"), "utf8")).toBe("# keep\r\nfoo\r\n/.antgrid/handoff/\r\n");
  });

  it("anchors the pattern at the show-prefix for a subdirectory root", async () => {
    const dir = repo();
    const sub = join(dir, "packages", "app");
    mkdirSync(sub, { recursive: true });
    expect(await ensureHandoffExcluded(sub, ID)).toBe("excluded");
    expect(readFileSync(join(dir, ".git", "info", "exclude"), "utf8")).toContain("/packages/app/.antgrid/handoff/");
    dropHandoffFile(sub);
    expect(git(dir, "status", "--porcelain")).toBe("");
  });

  it("returns not-git and writes nothing outside a repository", async () => {
    const dir = tmp();
    expect(await ensureHandoffExcluded(dir, ID)).toBe("not-git");
    expect(existsSync(join(dir, ".antgrid"))).toBe(false);
  });

  it("falls back to a self-ignoring .gitignore when a negation defeats the exclude", async () => {
    const dir = repo();
    writeFileSync(join(dir, ".gitignore"), "!/.antgrid/handoff/\n");
    expect(await ensureHandoffExcluded(dir, ID)).toBe("fallback-gitignore");
    expect(readFileSync(join(dir, ".antgrid", "handoff", ".gitignore"), "utf8")).toBe("*\n");
    dropHandoffFile(dir);
    expect(git(dir, "status", "--porcelain", "--", ".antgrid")).toBe("");
  });

  it("escapes glob characters in the prefix so the rule cannot widen to siblings", async () => {
    const dir = repo();
    const odd = join(dir, "a[b]");
    mkdirSync(odd);
    mkdirSync(join(dir, "ab"));
    expect(await ensureHandoffExcluded(odd, ID)).toBe("excluded");
    expect(readFileSync(join(dir, ".git", "info", "exclude"), "utf8")).toContain("/a\\[b\\]/.antgrid/handoff/");
    dropHandoffFile(odd);
    dropHandoffFile(join(dir, "ab"));
    const status = git(dir, "status", "--porcelain", "-uall");
    expect(status).toContain("ab/.antgrid/handoff/");
    expect(status).not.toContain("a[b]");
  });

  it("falls back when the exclude file cannot be written", async () => {
    const dir = repo();
    rmSync(join(dir, ".git", "info", "exclude"), { force: true });
    mkdirSync(join(dir, ".git", "info", "exclude"), { recursive: true });
    expect(await ensureHandoffExcluded(dir, ID)).toBe("fallback-gitignore");
    expect(existsSync(join(dir, ".antgrid", "handoff", ".gitignore"))).toBe(true);
  });
});
