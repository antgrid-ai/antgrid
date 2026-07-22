// bridge/src/git.ts

export type GitFileStatusCode = "M" | "A" | "D" | "?";

export interface GitFileEntry {
  path: string;
  status: GitFileStatusCode;
}

export interface GitOpResult {
  success: boolean;
  error?: string;
}

export interface GitCommitResult extends GitOpResult {
  sha?: string;
}

async function runGit(
  cwd: string,
  args: string[],
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  // `core.quotepath=false` keeps non-ASCII paths verbatim (UTF-8) instead of
  // git's default C-quoted/octal-escaped form (e.g. "caf\303\251.txt"). The
  // quoted form is a *literal* string that no longer matches the real file, so
  // status paths would round-trip into `add`/`restore`/`clean` pathspecs that
  // match nothing. Harmless for the pathspec-input verbs; load-bearing here.
  const proc = Bun.spawn(["git", "-c", "core.quotepath=false", ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  return { exitCode, stdout, stderr };
}

/**
 * Working-tree status vs HEAD: tracked changes (M/A/D) plus untracked
 * files ("?"). Renames from `--name-status` carry a similarity suffix
 * (e.g. "R100"), so they never match the M/A/D filter and are intentionally
 * dropped — same as the prior `git diff HEAD` behavior; the diff/commit UI
 * keys off plain M/A/D.
 */
export async function getGitStatus(cwd: string): Promise<GitFileEntry[]> {
  const entries: GitFileEntry[] = [];

  const tracked = await runGit(cwd, ["diff", "HEAD", "--relative", "--name-status"]);
  if (tracked.exitCode === 0) {
    for (const line of tracked.stdout.trim().split("\n")) {
      if (!line) continue;
      const [statusChar, ...pathParts] = line.split("\t");
      const status = statusChar?.trim();
      const filePath = pathParts.join("\t");
      if (status && filePath && ["M", "A", "D"].includes(status)) {
        entries.push({ path: filePath, status: status as GitFileStatusCode });
      }
    }
  }

  const untracked = await runGit(cwd, ["ls-files", "--others", "--exclude-standard"]);
  if (untracked.exitCode === 0) {
    for (const line of untracked.stdout.trim().split("\n")) {
      const p = line.trim();
      if (p) entries.push({ path: p, status: "?" });
    }
  }

  return entries;
}

/** Stage exactly `files`, then commit with `message`. Returns the new short SHA. */
export async function gitCommit(
  cwd: string,
  message: string,
  files: string[],
): Promise<GitCommitResult> {
  if (!message.trim()) return { success: false, error: "Commit message is empty" };
  if (files.length === 0) return { success: false, error: "No files selected" };

  const add = await runGit(cwd, ["add", "--", ...files]);
  if (add.exitCode !== 0) {
    return { success: false, error: add.stderr.trim() || "git add failed" };
  }

  // Scope the commit to a pathspec (partial commit via a temp index) so only
  // the selected files land — anything staged out-of-band (external CLI, a
  // prior agent) stays out, honoring the stage-on-commit promise.
  const commit = await runGit(cwd, ["commit", "-m", message, "--", ...files]);
  if (commit.exitCode !== 0) {
    return { success: false, error: commit.stderr.trim() || "git commit failed" };
  }

  // `git commit` prints "[<ref> <shorthash>] <subject>" on stdout (with an
  // optional "(root-commit)"; <ref> may itself contain a space as in
  // "detached HEAD"). Match the last hex token before the "]" rather than
  // paying a third `rev-parse` fork; sha is best-effort (left undefined if the
  // summary format ever changes).
  const sha = commit.stdout.match(/^\[.+ ([0-9a-f]{7,40})\]/m)?.[1];
  return { success: true, sha };
}

/**
 * Discard working-tree changes. Tracked files are restored to HEAD
 * (`git restore`, falling back to `git checkout --` on old git); untracked
 * files are deleted (`git clean -f`, files only — no `-d`). Both are
 * unrecoverable; callers gate on a confirm dialog.
 *
 * Tracked-vs-untracked is classified from LIVE git state here, not a cached
 * status snapshot: a file can flip tracked/untracked between the last status
 * poll and this call, and misrouting an untracked file to `restore` (errors)
 * or a tracked file to `clean` (silent no-op) would misreport the result.
 */
export async function gitDiscard(
  cwd: string,
  files: string[],
): Promise<GitOpResult> {
  if (files.length === 0) return { success: true };

  const others = await runGit(cwd, [
    "ls-files",
    "--others",
    "--exclude-standard",
    "--",
    ...files,
  ]);
  const untrackedSet = new Set(
    others.exitCode === 0
      ? others.stdout.trim().split("\n").map((l) => l.trim()).filter(Boolean)
      : [],
  );
  const tracked = files.filter((f) => !untrackedSet.has(f));
  const untracked = files.filter((f) => untrackedSet.has(f));

  if (tracked.length) {
    let r = await runGit(cwd, ["restore", "--", ...tracked]);
    if (r.exitCode !== 0) {
      r = await runGit(cwd, ["checkout", "--", ...tracked]);
      if (r.exitCode !== 0) {
        return { success: false, error: r.stderr.trim() || "Discard failed" };
      }
    }
  }

  if (untracked.length) {
    const r = await runGit(cwd, ["clean", "-f", "--", ...untracked]);
    if (r.exitCode !== 0) {
      return { success: false, error: r.stderr.trim() || "Discard failed" };
    }
  }

  return { success: true };
}
