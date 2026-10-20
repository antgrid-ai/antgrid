import { existsSync, statSync } from "node:fs";
import { mkdir, open, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { logger } from "../logger";
import { createKeyedLock } from "../keyed-lock";
import { runGit } from "../worktrees/project-resolver";

const log = logger.child({ component: "handoff-git-exclude" });

export type HandoffExcludeResult = "excluded" | "not-git" | "fallback-gitignore";

// Two forks into one repository race on the same exclude file.
const withExcludeFile = createKeyedLock();

function insideGitCheckout(start: string): boolean {
  let dir = resolve(start);
  for (;;) {
    if (existsSync(join(dir, ".git"))) return true;
    const parent = dirname(dir);
    if (parent === dir) return false;
    dir = parent;
  }
}

async function appendPattern(excludePath: string, pattern: string): Promise<void> {
  let current = "";
  try {
    current = await readFile(excludePath, "utf8");
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
  if (current.split(/\r?\n/).some((line) => line.trim() === pattern)) return;
  const eol = current.includes("\r\n") ? "\r\n" : "\n";
  const lead = current.length > 0 && !current.endsWith("\n") ? eol : "";
  // Appended in place rather than written through a temp file and renamed: the
  // bridge's own git poller can hold the exclude open (rename fails with EPERM
  // on Windows), a rename would drop a concurrent append from another process,
  // and it would replace an exclude file that is a symlink.
  const handle = await open(excludePath, "a");
  try {
    await handle.write(`${lead}${pattern}${eol}`);
  } finally {
    await handle.close();
  }
}

async function writeFallbackIgnore(handoffRoot: string): Promise<"fallback-gitignore"> {
  const dir = join(handoffRoot, ".antgrid", "handoff");
  await mkdir(dir, { recursive: true });
  await writeFile(join(dir, ".gitignore"), "*\n");
  // Antigravity may refuse to read paths a .gitignore lists, which the
  // info/exclude route does not trigger.
  log.warn("handoff files are hidden from git through a .gitignore because info/exclude could not be used; an agent that skips gitignored paths may not read them");
  return "fallback-gitignore";
}

/**
 * Keeps `<handoffRoot>/.antgrid/handoff/` out of `git status`. An untracked
 * handoff file would also make the worktree manager refuse to delete the
 * checkout as dirty.
 *
 * Uses the repository-wide `info/exclude`: git ignores a linked worktree's own
 * `info/exclude`, so the file has to be the common dir's. Never throws for a git
 * failure; it falls back to a self-ignoring `.gitignore` instead.
 */
export async function ensureHandoffExcluded(handoffRoot: string, id: string): Promise<HandoffExcludeResult> {
  try {
    const revParse = await runGit(["rev-parse", "--git-common-dir", "--show-prefix"], handoffRoot);
    if (revParse.exitCode !== 0) {
      if (!insideGitCheckout(handoffRoot)) return "not-git";
      return await writeFallbackIgnore(handoffRoot);
    }
    const [commonRaw, prefixRaw = ""] = revParse.stdout.split(/\r?\n/);
    const commonDir = resolve(handoffRoot, (commonRaw ?? "").trim());
    let commonIsDir = false;
    try { commonIsDir = statSync(commonDir).isDirectory(); } catch { /* reported below */ }
    if (!commonIsDir) {
      // An MSYS or Cygwin git answers with a `/c/...` path this process cannot open.
      log.warn("git common dir %s is not a directory here", commonRaw);
      return await writeFallbackIgnore(handoffRoot);
    }
    const prefix = prefixRaw.trim();
    const pattern = `/${prefix}.antgrid/handoff/`;
    const excludePath = join(commonDir, "info", "exclude");
    try {
      await withExcludeFile(excludePath, async () => {
        await mkdir(dirname(excludePath), { recursive: true });
        await appendPattern(excludePath, pattern);
      });
    } catch (error) {
      log.warn("could not write %s: %s", excludePath, error instanceof Error ? error.message : String(error));
      return await writeFallbackIgnore(handoffRoot);
    }
    // A `.gitignore` negation outranks info/exclude, so the pattern alone proves nothing.
    const ignored = await runGit(["check-ignore", "-q", `.antgrid/handoff/${id}/manifest.json`], handoffRoot);
    if (ignored.exitCode === 0) return "excluded";
    return await writeFallbackIgnore(handoffRoot);
  } catch (error) {
    log.warn("handoff exclude failed: %s", error instanceof Error ? error.message : String(error));
    try { return await writeFallbackIgnore(handoffRoot); } catch { return "not-git"; }
  }
}
