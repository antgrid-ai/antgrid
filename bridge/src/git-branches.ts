export interface GitBranchCatalog {
  isRepository: boolean;
  current: string | null;
  branches: string[];
  worktreeSessionsSupported: boolean;
}

export class GitHelperError extends Error {
  constructor(
    public readonly code: "NOT_GIT_REPOSITORY" | "UNKNOWN_BRANCH" | "CHECKOUT_FAILED",
    message: string,
  ) {
    super(message);
    this.name = "GitHelperError";
  }
}

export async function listLocalBranches(projectPath: string): Promise<GitBranchCatalog> {
  // Check if inside work tree
  const revParseProc = Bun.spawn(["git", "rev-parse", "--is-inside-work-tree"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });
  const revParseExit = await revParseProc.exited;
  if (revParseExit !== 0) {
    return {
      isRepository: false,
      current: null,
      branches: [],
      worktreeSessionsSupported: false,
    };
  }

  // Concurrent reads
  const currentProc = Bun.spawn(["git", "branch", "--show-current"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });
  const refsProc = Bun.spawn(["git", "for-each-ref", "--format=%(refname:short)", "refs/heads"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });

  const [currentText, refsText] = await Promise.all([
    new Response(currentProc.stdout).text(),
    new Response(refsProc.stdout).text(),
  ]);

  await Promise.all([currentProc.exited, refsProc.exited]);

  const rawCurrent = currentText.trim();
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

  const proc = Bun.spawn(["git", "switch", branch], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });

  const stderr = (await new Response(proc.stderr).text()).trim();
  const exitCode = await proc.exited;

  if (exitCode !== 0) {
    throw new GitHelperError(
      known ? "CHECKOUT_FAILED" : "UNKNOWN_BRANCH",
      stderr || `git switch ${branch} failed with exit code ${exitCode}`,
    );
  }

  // Re-verify current branch
  const verifyProc = Bun.spawn(["git", "branch", "--show-current"], {
    cwd: projectPath,
    stdout: "pipe",
    stderr: "pipe",
  });
  const verifyText = (await new Response(verifyProc.stdout).text()).trim();
  await verifyProc.exited;

  if (verifyText !== branch) {
    throw new GitHelperError("CHECKOUT_FAILED", `Verification failed: expected branch '${branch}', got '${verifyText}'`);
  }

  return { current: branch };
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
 * `ls-remote` reaches the network, so it can sit forever on a credential prompt
 * or a black-holed host. GIT_TERMINAL_PROMPT=0 turns the prompt into a failure
 * and the kill timer bounds the rest. Same shape as handler/snapshot.ts.
 */
export async function runGitRemote(
  cwd: string,
  args: string[],
  timeoutMs?: number,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const proc = Bun.spawn(["git", ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, LC_ALL: "C", GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0" },
  });
  const settled = (async () => {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    return { exitCode: await proc.exited, stdout, stderr };
  })();
  if (!timeoutMs) return settled;

  // The deadline races the READS, not just the process. Killing git alone does
  // not end them: `ls-remote` over ssh hands its stdout/stderr pipes to a child
  // `ssh`, which keeps the write ends open — and against a black-holed host
  // that child outlives the timer by ssh's own connect timeout, so awaiting the
  // pipes here would blow the UI deadline this exists to hold.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<null>((resolve) => {
    timer = setTimeout(() => {
      proc.kill();
      resolve(null);
    }, timeoutMs);
  });
  // The loser keeps running with nobody awaiting it; it never rejects, but the
  // handler is what keeps that from being reported as an unhandled rejection.
  settled.catch(() => undefined);
  const won = await Promise.race([settled, deadline]);
  clearTimeout(timer);
  return won ?? { exitCode: 124, stdout: "", stderr: `git ${args[0]} exceeded ${timeoutMs}ms` };
}

/** Short branch name this branch pushes to, from tracking config; falls back to
 *  same-name-on-origin, which is what a first push would create. `tracked`
 *  reports which of the two it was, because a missing ref means "deleted" only
 *  when config claimed one — a `.` remote (tracking a LOCAL branch) is a
 *  fallback, not tracking. */
export async function resolvePushTarget(
  projectPath: string,
  branch: string,
): Promise<{ remote: string; remoteBranch: string; tracked: boolean } | null> {
  const [remoteCfg, mergeCfg] = await Promise.all([
    runGitRemote(projectPath, ["config", "--get", `branch.${branch}.remote`]),
    runGitRemote(projectPath, ["config", "--get", `branch.${branch}.merge`]),
  ]);
  const remote = remoteCfg.stdout.trim();
  const merge = mergeCfg.stdout.trim();

  if (remote && remote !== ".") {
    // `merge` is a full ref (refs/heads/x); absent means push.default names it
    // after the local branch.
    const remoteBranch = merge.startsWith("refs/heads/") ? merge.slice("refs/heads/".length) : branch;
    return { remote, remoteBranch, tracked: true };
  }

  const remotes = await runGitRemote(projectPath, ["remote"]);
  const names = remotes.stdout.split(/\r?\n/).map((n) => n.trim()).filter(Boolean);
  if (names.length === 0) return null;
  return { remote: names.includes("origin") ? "origin" : names[0]!, remoteBranch: branch, tracked: false };
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
