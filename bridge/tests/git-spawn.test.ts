import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdtempSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runGit } from "../src/git-spawn";

/** A bare spawn, deliberately WITHOUT the shared runner's environment. Every
 *  assertion about what that environment buys is paired with one of these, so
 *  a test cannot pass by asserting something that was true anyway. */
async function runBare(cwd: string, args: string[]) {
  const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  const stdout = await new Response(proc.stdout).text();
  await proc.exited;
  return stdout;
}

describe("the shared git runner", () => {
  let dir: string;

  beforeEach(async () => {
    dir = mkdtempSync(join(tmpdir(), "antgrid-git-spawn-"));
    await runBare(dir, ["init"]);
    await runBare(dir, ["config", "user.email", "test@antgrid.local"]);
    await runBare(dir, ["config", "user.name", "Test"]);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("keeps a non-ASCII path verbatim where a bare git escapes it", async () => {
    writeFileSync(join(dir, "café.txt"), "x");

    const { stdout } = await runGit(dir, ["status", "--porcelain"]);
    expect(stdout).toContain("café.txt");

    // The pairing: without core.quotepath=false the same path comes back as a
    // C-quoted octal string, which is a literal that no longer names the file.
    const bare = await runBare(dir, ["status", "--porcelain"]);
    expect(bare).not.toContain("café.txt");
    expect(bare).toContain(String.raw`\303\251`);
  });

  it("leaves the index alone where a bare git status rewrites it", async () => {
    const file = join(dir, "tracked.txt");
    writeFileSync(file, "content\n");
    await runBare(dir, ["add", "."]);
    await runBare(dir, ["commit", "-m", "seed"]);

    // A stat that no longer matches the index entry is what makes git want to
    // write a refreshed index back. The content is untouched, so the file is
    // still clean and the only thing at stake is the courtesy write.
    const future = new Date(Date.now() + 10_000);
    utimesSync(file, future, future);
    const before = statSync(join(dir, ".git", "index")).mtimeMs;

    await runGit(dir, ["status", "--porcelain"]);
    expect(statSync(join(dir, ".git", "index")).mtimeMs).toBe(before);

    // The pairing: a bare status takes `index.lock` and writes, which is the
    // race against the user's own git this exists to stay out of.
    await runBare(dir, ["status", "--porcelain"]);
    expect(statSync(join(dir, ".git", "index")).mtimeMs).not.toBe(before);
  });

  it("still lets a write verb take the lock it genuinely needs", async () => {
    writeFileSync(join(dir, "staged.txt"), "content\n");

    const add = await runGit(dir, ["add", "."]);
    expect(add.exitCode).toBe(0);

    const { stdout } = await runGit(dir, ["status", "--porcelain"]);
    expect(stdout).toContain("A  staged.txt");
  });

  it("pins git's prose to English only when asked", async () => {
    const { stderr } = await runGit(dir, ["checkout", "no-such-branch"], {
      englishProse: true,
    });

    expect(stderr).toContain("did not match any file(s) known to git");
  });

  it("returns the real result when a deadline is never reached", async () => {
    // The deadline path replaces the result wholesale, so the no-timeout and
    // timeout branches have to agree for every command that finishes in time.
    const { exitCode } = await runGit(dir, ["status", "--porcelain"], {
      timeoutMs: 30_000,
    });

    expect(exitCode).toBe(0);
  });
});
