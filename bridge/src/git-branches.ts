import { runGit as runGitShared } from "./git-spawn";

export interface GitBranchCatalog {
  isRepository: boolean;
  current: string | null;
  branches: string[];
  worktreeSessionsSupported: boolean;
}

export class GitHelperError extends Error {
  constructor(
    public readonly code:
      | "NOT_GIT_REPOSITORY"
      | "UNKNOWN_BRANCH"
      | "CHECKOUT_FAILED"
      | "DIRTY_WORKTREE",
    message: string,
  ) {
    super(message);
    this.name = "GitHelperError";
  }
}

/** Longest file list a dirty-worktree refusal spells out before summarizing —
 * same shape as `unresolvedConflictError` in `git.ts`. */
const NAMED_DIRTY_FILES_IN_ERROR = 3;

/** Whether `stderr` is git's refusal to move HEAD over changes it would have
 * to overwrite — a tracked edit or an untracked file in the way — as opposed
 * to any other reason `git switch` can fail (a hook, a submodule, detached
 * HEAD oddities). Both of git's own wordings ("...by checkout" for a plain
 * switch, "...by merge" when the switch itself performs a merge) share this
 * clause, so matching on it covers both without depending on which one fired. */
function isDirtyWorktreeRefusal(stderr: string): boolean {
  return stderr.includes("would be overwritten by");
}

/** The path list `git switch` prints directly under either "would be
 * overwritten" header, one per line, each indented with a single tab —
 * git's own format, not ours to construct. */
function parseOverwrittenFiles(stderr: string): string[] {
  return stderr
    .split(/\r?\n/)
    .filter((line) => line.startsWith("\t"))
    .map((line) => line.slice(1));
}

/** User-facing refusal for `DIRTY_WORKTREE`, naming what is actually in the
 * way — the raw git hint block ("Please commit your changes or stash them...")
 * reads as a terminal message, not app copy, and says nothing about WHICH
 * files. */
function dirtyWorktreeError(branch: string, files: string[]): string {
  if (files.length === 0) {
    return `Switching to "${branch}" would overwrite uncommitted changes. Commit, stash, or discard them first.`;
  }
  const named = files.slice(0, NAMED_DIRTY_FILES_IN_ERROR).join(", ");
  const rest = files.length - NAMED_DIRTY_FILES_IN_ERROR;
  const list = rest > 0 ? `${named} and ${rest} more` : named;
  return `Switching to "${branch}" would overwrite uncommitted changes in: ${list}. Commit, stash, or discard them first.`;
}

export async function listLocalBranches(projectPath: string): Promise<GitBranchCatalog> {
  // Check if inside work tree
  const revParse = await runGit(projectPath, ["rev-parse", "--is-inside-work-tree"]);
  if (revParse.exitCode !== 0) {
    return {
      isRepository: false,
      current: null,
      branches: [],
      worktreeSessionsSupported: false,
    };
  }

  // Concurrent reads
  const [currentRun, refsRun] = await Promise.all([
    runGit(projectPath, ["branch", "--show-current"]),
    runGit(projectPath, ["for-each-ref", "--format=%(refname:short)", "refs/heads"]),
  ]);
  const refsText = refsRun.stdout;

  const rawCurrent = currentRun.stdout.trim();
  const current = rawCurrent.length > 0 ? rawCurrent : null;

  const rawBranches = refsText
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  // Deduplicate preserving order
  const uniqueBranches = Array.from(new Set(rawBranches));

  // Sort: current first if present, remainder sorted case-insensitively with exact string tie-breaker
  const otherBranches = uniqueBranches.filter((b) => b !== current);
  otherBranches.sort((a, b) => {
    const lowerA = a.toLowerCase();
    const lowerB = b.toLowerCase();
    if (lowerA < lowerB) return -1;
    if (lowerA > lowerB) return 1;
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
  });

  const finalBranches: string[] = [];
  if (current && uniqueBranches.includes(current)) {
    finalBranches.push(current);
  }
  finalBranches.push(...otherBranches);

  return {
    isRepository: true,
    current,
    branches: finalBranches,
    worktreeSessionsSupported: false,
  };
}

export async function checkoutLocalBranch(
  projectPath: string,
  branch: string,
): Promise<{ current: string }> {
  const catalog = await listLocalBranches(projectPath);
  if (!catalog.isRepository) {
    throw new GitHelperError("NOT_GIT_REPOSITORY", "Not a Git repository");
  }

  // Advisory, never a refusal. `git switch feature` in a fresh clone DWIMs
  // `origin/feature` into a tracking branch, and this catalog is local heads
  // only — so a whitelist here is an Antgrid-side limit on top of Git's, and
  // one that cannot be repaired by widening it (the DWIM is a `switch` rule,
  // not a ref-resolution rule: `rev-parse feature` still fails there). Git
  // decides; this only picks which code its refusal is reported under.
  const known = catalog.branches.includes(branch);

  // The catalog no longer bounds this string, so nothing else stops it reaching
  // argv as an OPTION: `git switch --detach` and `git switch -` both exit 0 and
  // move HEAD in the user's real checkout, and the verification below then
  // reports a failure the tree has already suffered. Git forbids a ref starting
  // with `-`, so no reachable branch is lost by refusing one here.
  //
  // `@{-1}` is the same hazard spelled without a leading `-`: `git switch` also
  // resolves it, moves HEAD, exits 0, and only then fails verification. Git
  // forbids `@{` inside a ref name too, so this loses nothing either.
  if (branch.length === 0 || branch.startsWith("-") || branch.includes("@{")) {
    throw new GitHelperError("UNKNOWN_BRANCH", `Branch '${branch}' does not exist`);
  }

  if (catalog.current === branch) {
    return { current: branch };
  }

  const attemptSwitch = async (): Promise<{ dirty: string[] } | null> => {
    // Through [runGit] for its `LC_ALL=C`: the two things read off this stderr
    // — [isDirtyWorktreeRefusal] and [parseOverwrittenFiles] — are matches on
    // git's own ENGLISH wording, so on a localized git a bare spawn reports
    // every dirty-worktree refusal as CHECKOUT_FAILED.
    const { exitCode, stderr: rawStderr } = await runGit(projectPath, ["switch", branch]);
    const stderr = rawStderr.trim();
    if (exitCode !== 0) {
      if (known && isDirtyWorktreeRefusal(stderr)) {
        return { dirty: parseOverwrittenFiles(stderr) };
      }
      throw new GitHelperError(
        known ? "CHECKOUT_FAILED" : "UNKNOWN_BRANCH",
        stderr || `git switch ${branch} failed with exit code ${exitCode}`,
      );
    }
    return null;
  };

  const dirty = await attemptSwitch();
  if (dirty) {
    throw new GitHelperError("DIRTY_WORKTREE", dirtyWorktreeError(branch, dirty.dirty));
  }

  await verifyCurrentBranch(projectPath, branch);
  return { current: branch };
}

/** Confirms `git switch` actually moved HEAD. */
async function verifyCurrentBranch(projectPath: string, branch: string): Promise<void> {
  const verify = await runGit(projectPath, ["branch", "--show-current"]);
  const verifyText = verify.stdout.trim();

  if (verifyText !== branch) {
    throw new GitHelperError("CHECKOUT_FAILED", `Verification failed: expected branch '${branch}', got '${verifyText}'`);
  }
}

/** Local (non-network) git in this module. Deliberately [runGitRemote] with no
 *  deadline rather than a bare spawn: its `LC_ALL=C` is what makes every prose
 *  matcher here — [isDirtyWorktreeRefusal]'s `would be overwritten by` — a fact rather than a guess about the user's
 *  locale. */
async function runGit(
  cwd: string,
  args: string[],
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return runGitRemote(cwd, args);
}


/**
 * How a local branch stands against the branch it pushes to on the remote,
 * measured by asking the remote — NOT by reading `refs/remotes/*`, which only
 * moves on fetch/pull and so reports "in sync" against an arbitrarily old
 * snapshot. Nothing in the bridge keeps those refs warm.
 *
 * - `no-remote`     — nothing to compare against.
 * - `no-upstream`   — branch never pushed / no tracking config and no origin match.
 * - `gone`          — the remote branch existed once and does not now.
 * - `in-sync`       — same commit.
 * - `behind` / `ahead` / `diverged` — with counts, when the remote commit is
 *   already an object in this repo.
 * - `differs`       — the remote commit is unknown locally, which PROVES the
 *   remote holds work this branch does not. Counts need a fetch, so there are
 *   none; saying "behind" would be a guess (the local side may also be ahead).
 * - `unreachable`   — offline, auth needed, or slower than the deadline.
 */
export type BranchRemoteState =
  | "no-remote" | "no-upstream" | "gone" | "in-sync"
  | "behind" | "ahead" | "diverged" | "differs" | "unreachable";

export interface BranchRemoteStatus {
  branch: string;
  state: BranchRemoteState;
  /** Remote name (`origin`) and the short branch name on it, when resolved. */
  remote?: string;
  remoteBranch?: string;
  /** Only for behind/ahead/diverged — see `differs` above. */
  behind?: number;
  ahead?: number;
  /** Why `unreachable`, for logs. Never surfaced as UI copy. */
  detail?: string;
}

// The user is waiting on this with a branch chip open, so the deadline is a UI
// deadline, not git's. Missing the window degrades to `unreachable` (silent in
// the UI); it never blocks starting a session.
const LS_REMOTE_TIMEOUT_MS = 6_000;

/**
 * `ls-remote` reaches the network, so it can sit indefinitely on a black-holed
 * host; the deadline is the only thing that bounds it. Kept as a named entry
 * point because [runGit] below is defined as "this, without a deadline" — the
 * locale pin both of them need is the same either way.
 */
export async function runGitRemote(
  cwd: string,
  args: string[],
  timeoutMs?: number,
  env?: Record<string, string | undefined>,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return runGitShared(cwd, args, { englishProse: true, timeoutMs, env });
}

/** Short branch name this branch pushes to, from tracking config; falls back to
 *  same-name-on-origin, which is what a first push would create. `tracked`
 *  reports which of the two it was, because a missing ref means "deleted" only
 *  when config claimed one — a `.` remote (tracking a LOCAL branch) is a
 *  fallback, not tracking.
 *
 *  `hasTrackingConfig` answers a narrower question and is NOT interchangeable
 *  with `tracked`: it reports whether `branch.<n>.remote` is set AT ALL, which
 *  is the git-level precondition for `@{upstream}` resolving. A `.` remote
 *  leaves the fallback arm with `tracked: false` while `@{upstream}` still
 *  resolves, so anything gating an upstream read on `tracked` silently zeroes
 *  the counts of a branch that tracks a local one. */
export async function resolvePushTarget(
  projectPath: string,
  branch: string,
): Promise<
  { remote: string; remoteBranch: string; tracked: boolean; hasTrackingConfig: boolean } | null
> {
  const [remoteCfg, mergeCfg] = await Promise.all([
    runGitRemote(projectPath, ["config", "--get", `branch.${branch}.remote`]),
    runGitRemote(projectPath, ["config", "--get", `branch.${branch}.merge`]),
  ]);
  const remote = remoteCfg.stdout.trim();
  const merge = mergeCfg.stdout.trim();

  const hasTrackingConfig = remote.length > 0;

  if (remote && remote !== ".") {
    // `merge` is a full ref (refs/heads/x); absent means push.default names it
    // after the local branch.
    const remoteBranch = merge.startsWith("refs/heads/") ? merge.slice("refs/heads/".length) : branch;
    return { remote, remoteBranch, tracked: true, hasTrackingConfig };
  }

  const remotes = await runGitRemote(projectPath, ["remote"]);
  const names = remotes.stdout.split(/\r?\n/).map((n) => n.trim()).filter(Boolean);
  if (names.length === 0) return null;
  return {
    remote: names.includes("origin") ? "origin" : names[0]!,
    remoteBranch: branch,
    tracked: false,
    hasTrackingConfig,
  };
}

export async function checkBranchAgainstRemote(
  projectPath: string,
  branch: string,
): Promise<BranchRemoteStatus> {
  const localRev = await runGitRemote(projectPath, ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}^{commit}`]);
  const localSha = localRev.stdout.trim();
  if (localRev.exitCode !== 0 || !localSha) {
    throw new GitHelperError("UNKNOWN_BRANCH", `Branch '${branch}' does not exist`);
  }

  const target = await resolvePushTarget(projectPath, branch);
  if (!target) return { branch, state: "no-remote" };

  const ls = await runGitRemote(
    projectPath,
    ["ls-remote", "--heads", "--", target.remote, `refs/heads/${target.remoteBranch}`],
    LS_REMOTE_TIMEOUT_MS,
  );
  const base = { branch, remote: target.remote, remoteBranch: target.remoteBranch };
  if (ls.exitCode !== 0) {
    return { ...base, state: "unreachable", detail: ls.stderr.trim() || `git ls-remote exited ${ls.exitCode}` };
  }

  const row = ls.stdout
    .split(/\r?\n/)
    .map((line) => line.split("\t"))
    .find((cols) => cols.length === 2 && cols[1]!.trim() === `refs/heads/${target.remoteBranch}`);
  if (!row) {
    // Tracking config for a ref the remote does not have means it was deleted;
    // without it the target above is only the same-name-on-origin guess, so the
    // branch simply was never pushed.
    return { ...base, state: target.tracked ? "gone" : "no-upstream" };
  }

  const remoteSha = row[0]!.trim();
  if (remoteSha === localSha) return { ...base, state: "in-sync" };

  // Counts need the remote commit as a local object. Right after a fetch it is
  // there; otherwise `differs` is the whole honest answer.
  const have = await runGitRemote(projectPath, ["cat-file", "-e", `${remoteSha}^{commit}`]);
  if (have.exitCode !== 0) return { ...base, state: "differs" };

  const counts = await runGitRemote(projectPath, ["rev-list", "--left-right", "--count", `${remoteSha}...${localSha}`]);
  const [behindRaw, aheadRaw] = counts.stdout.trim().split(/\s+/);
  const behind = Number(behindRaw);
  const ahead = Number(aheadRaw);
  if (counts.exitCode !== 0 || !Number.isFinite(behind) || !Number.isFinite(ahead)) {
    return { ...base, state: "differs" };
  }
  if (behind > 0 && ahead > 0) return { ...base, state: "diverged", behind, ahead };
  if (behind > 0) return { ...base, state: "behind", behind, ahead: 0 };
  if (ahead > 0) return { ...base, state: "ahead", behind: 0, ahead };
  return { ...base, state: "in-sync" };
}
