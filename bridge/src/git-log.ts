// bridge/src/git-log.ts
// Commit history: the paginated log the History tab scrolls through, and the
// per-commit file list + diff it drills into. Kept apart from `git.ts`
// (working-tree status/diff/commit) and `git-branches.ts` (branch catalog +
// checkout) — a third, read-only concern with its own small git-invocation
// helper, matching how those two modules are already split.

async function runGit(
  cwd: string,
  args: string[],
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  // core.quotepath=false: see git.ts's [runGit] — same non-ASCII-path reason.
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

export interface GitLogEntry {
  sha: string;
  shortSha: string;
  subject: string;
  authorName: string;
  authorEmail: string;
  /** ISO 8601, author date (not committer date) — what every other git UI
   *  sorts and labels by. */
  authorDate: string;
}

/** Field/record separators for `git log --pretty=format:` — ASCII unit/record
 *  separators, control characters a commit subject cannot contain, so no
 *  escaping is needed the way path-quoting needs `-z` elsewhere in this file. */
const LOG_FIELD_SEP = "\x1f";
const LOG_RECORD_SEP = "\x1e";

/**
 * One page of `git log`, newest first. `skip`/`limit` are a plain offset
 * (git's own `--skip`/`-n`), not a commit-hash cursor: the History tab is
 * read-only and each page is fetched once as the user scrolls, so the extra
 * correctness a hash cursor buys against a mid-scroll rebase isn't worth the
 * bridge tracking state for it. Requests `limit + 1` to answer [hasMore]
 * without a second round trip.
 */
export async function getGitLog(
  cwd: string,
  skip: number,
  limit: number,
): Promise<{ commits: GitLogEntry[]; hasMore: boolean }> {
  const format = ["%H", "%h", "%an", "%ae", "%aI", "%s"].join(LOG_FIELD_SEP);
  const r = await runGit(cwd, [
    "log",
    `--skip=${skip}`,
    `-n${limit + 1}`,
    `--pretty=format:${format}${LOG_RECORD_SEP}`,
  ]);
  // Non-zero here is almost always "no commits yet" (unborn HEAD) rather than
  // a real failure — an empty page is the honest answer either way.
  if (r.exitCode !== 0) return { commits: [], hasMore: false };

  const records = r.stdout
    .split(LOG_RECORD_SEP)
    .map((rec) => (rec.startsWith("\n") ? rec.slice(1) : rec))
    .filter((rec) => rec.length > 0);
  const hasMore = records.length > limit;
  const commits = records.slice(0, limit).map((record) => {
    const [sha, shortSha, authorName, authorEmail, authorDate, ...subjectParts] =
      record.split(LOG_FIELD_SEP);
    return {
      sha: sha ?? "",
      shortSha: shortSha ?? "",
      authorName: authorName ?? "",
      authorEmail: authorEmail ?? "",
      authorDate: authorDate ?? "",
      subject: subjectParts.join(LOG_FIELD_SEP),
    };
  });
  return { commits, hasMore };
}

export type GitCommitFileStatus = "M" | "A" | "D" | "R";

export interface GitCommitFileEntry {
  path: string;
  status: GitCommitFileStatus;
  /** Pre-rename path; set only when status is "R". */
  oldPath?: string;
  additions: number;
  deletions: number;
}

/** Diff-tree flags shared by [getCommitFiles] and [getCommitFileDiff] — both
 *  must agree on which tree a commit is compared against, or the file list a
 *  user expands and the diff they then open could describe two different
 *  changes. `--root` diffs the very first commit against the empty tree
 *  instead of erroring for lack of a parent; `-m --first-parent` picks a
 *  merge's mainline (the branch that was actually checked out) rather than
 *  git's default of emitting nothing for a merge commit. */
const COMMIT_DIFF_FLAGS = ["-M", "-r", "-m", "--first-parent", "--root", "--relative"];

/** name-status -z: `<code>\0<path>\0` for a plain change, or
 *  `R<score>\0<oldpath>\0<newpath>\0` for a detected rename — same shape
 *  [parsePorcelain] documents in git.ts, minus the X/Y split (a commit has no
 *  index vs worktree). */
function parseNameStatusZ(stdout: string): Map<string, { status: GitCommitFileStatus; oldPath?: string }> {
  const out = new Map<string, { status: GitCommitFileStatus; oldPath?: string }>();
  const tokens = stdout.split("\0").filter((t) => t.length > 0);
  for (let i = 0; i < tokens.length; i++) {
    const code = tokens[i]![0];
    if (code === "R" || code === "C") {
      const oldPath = tokens[++i];
      const newPath = tokens[++i];
      if (newPath !== undefined) out.set(newPath, { status: "R", oldPath });
      continue;
    }
    const path = tokens[++i];
    if (path === undefined) continue;
    out.set(path, { status: code === "A" ? "A" : code === "D" ? "D" : "M" }); // folds "T"
  }
  return out;
}

/** numstat -z, same record shape [getDiffStats] parses in git.ts (see its own
 *  doc for the empty-path/rename-pair case). */
function parseNumstatZ(stdout: string): Map<string, { additions: number; deletions: number }> {
  const out = new Map<string, { additions: number; deletions: number }>();
  const tokens = stdout.split("\0").filter((t) => t.length > 0);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i]!;
    const firstTab = token.indexOf("\t");
    const secondTab = firstTab === -1 ? -1 : token.indexOf("\t", firstTab + 1);
    if (firstTab === -1 || secondTab === -1) continue;
    const addedStr = token.slice(0, firstTab);
    const deletedStr = token.slice(firstTab + 1, secondTab);
    const additions = addedStr === "-" ? 0 : parseInt(addedStr, 10);
    const deletions = deletedStr === "-" ? 0 : parseInt(deletedStr, 10);
    const path = token.slice(secondTab + 1);
    if (path === "") {
      const newPath = tokens[i + 2];
      i += 2;
      if (newPath !== undefined) out.set(newPath, { additions, deletions });
      continue;
    }
    out.set(path, { additions, deletions });
  }
  return out;
}

/** Files one commit touched, combining `--name-status` (what changed) with
 *  `--numstat` (line counts) — one `diff-tree` invocation cannot report both
 *  at once, the same limitation [getDiffStats] works around for the working
 *  tree. */
export async function getCommitFiles(cwd: string, sha: string): Promise<GitCommitFileEntry[]> {
  const [nameStatus, numstat] = await Promise.all([
    runGit(cwd, ["diff-tree", "--no-commit-id", "--name-status", "-z", ...COMMIT_DIFF_FLAGS, sha]),
    runGit(cwd, ["diff-tree", "--no-commit-id", "--numstat", "-z", ...COMMIT_DIFF_FLAGS, sha]),
  ]);
  if (nameStatus.exitCode !== 0) return [];

  const statuses = parseNameStatusZ(nameStatus.stdout);
  const stats = numstat.exitCode === 0 ? parseNumstatZ(numstat.stdout) : new Map();

  const entries: GitCommitFileEntry[] = [];
  for (const [path, info] of statuses) {
    const { additions, deletions } = stats.get(path) ?? { additions: 0, deletions: 0 };
    entries.push({ path, status: info.status, oldPath: info.oldPath, additions, deletions });
  }
  return entries;
}

/** One file's diff within a single commit, in the same [COMMIT_DIFF_FLAGS]
 *  scope [getCommitFiles] built its list from — the file list a user expands
 *  and the diff they then open must describe the same change. */
export async function getCommitFileDiff(
  cwd: string,
  sha: string,
  path: string,
): Promise<{ diff: string | null; additions: number; deletions: number }> {
  const r = await runGit(cwd, [
    "diff-tree", "-p", "--no-commit-id", ...COMMIT_DIFF_FLAGS, sha, "--", path,
  ]);
  if (r.exitCode !== 0) return { diff: null, additions: 0, deletions: 0 };

  let additions = 0;
  let deletions = 0;
  for (const line of r.stdout.split("\n")) {
    if (line.startsWith("+") && !line.startsWith("+++")) additions++;
    if (line.startsWith("-") && !line.startsWith("---")) deletions++;
  }
  return { diff: r.stdout || null, additions, deletions };
}
