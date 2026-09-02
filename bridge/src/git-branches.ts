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
      | "DIRTY_WORKTREE"
      | "STASH_FAILED",
    message: string,
  ) {
    super(message);
    this.name = "GitHelperError";
  }
}

/** One `git stash` entry. `branch` is the branch HEAD pointed at when the
 *  stash was created, parsed off git's own reflog subject — stashes are a
 *  single list shared by the whole repository (every worktree included), so
 *  this is the only record of which branch a given entry belongs to. */
export interface StashEntry {
  /** e.g. `stash@{0}` — stable only until the NEXT push/pop/drop shifts the
   *  list, so callers must re-list rather than cache this across a mutation. */
  ref: string;
  /** "" when the subject doesn't match either of git's own formats (a stash
   *  made with `--no-keep-index` on a detached HEAD, e.g.) — never guessed. */
  branch: string;
  message: string;
  /** Unix seconds. */
  createdAt: number;
}

/** git's own reflog subject for a stash is either `WIP on <branch>: <sha>
 *  <subject>` (the default, no `-m`) or `On <branch>: <message>` (ours, since
 *  every push here passes `-m`) — both are OUR format to parse, not git's to
 *  document further; there is no third form. */
function parseStashSubject(subject: string): { branch: string; message: string } {
  const match = /^(?:WIP on|On) ([^:]+): (.*)$/.exec(subject);
  if (!match) return { branch: "", message: subject };
  return { branch: match[1]!, message: match[2]! };
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
  opts?: {
    /** On `DIRTY_WORKTREE`, stash the working tree (tracked + untracked, via
     *  `-u`) and retry the switch once, rather than refusing outright. The
     *  created stash is returned as `stashed` so the caller can surface a
     *  Restore/Discard affordance — nothing here pops it automatically, since
     *  the whole point is that the switch must not silently reapply changes
     *  that belong to the branch just left. */
    stashIfDirty?: boolean;
  },
): Promise<{ current: string; stashed?: StashEntry }> {
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
    // every dirty-worktree refusal as CHECKOUT_FAILED and never offers the
    // stash.
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
  let stashed: StashEntry | undefined;
  if (dirty) {
    if (!opts?.stashIfDirty) {
      throw new GitHelperError("DIRTY_WORKTREE", dirtyWorktreeError(branch, dirty.dirty));
    }
    // `-u` covers untracked files too — the same set `dirtyWorktreeError`
    // above would have named, since an untracked file in the way is exactly
    // what `isDirtyWorktreeRefusal` also matches.
    stashed = await stashPush(projectPath, `Before switching to ${branch}`);
    // EVERY failure past this point owes the pop, not just a second dirty
    // refusal: `attemptSwitch` THROWS for any other reason git can refuse (a
    // hook, a submodule, an `index.lock`), and the verification below throws
    // too — and on those paths the caller reports a checkout failure while the
    // user's tracked AND untracked work sits in a stash the error never
    // mentions. The tree is empty of it and nothing in the app lists it.
    try {
      const retried = await attemptSwitch();
      if (retried) {
        // The stash didn't clear whatever git objected to — put it back rather
        // than leaving the user's work stashed with the switch still refused,
        // and report the ORIGINAL dirty files so the message still names
        // something actionable.
        await stashPopBestEffort(projectPath, stashed.ref);
        throw new GitHelperError("DIRTY_WORKTREE", dirtyWorktreeError(branch, retried.dirty));
      }
      await verifyCurrentBranch(projectPath, branch);
    } catch (err) {
      // The `retried` arm above already popped and is re-thrown untouched;
      // everything else lands here with the stash still held.
      if (!(err instanceof GitHelperError && err.code === "DIRTY_WORKTREE")) {
        await stashPopBestEffort(projectPath, stashed.ref);
      }
      throw err;
    }
    return { current: branch, stashed };
  }

  await verifyCurrentBranch(projectPath, branch);
  return { current: branch, stashed };
}

/** Confirms `git switch` actually moved HEAD. Separate so the stash-and-retry
 *  path above can run it INSIDE its rollback guard — a verification failure
 *  after a successful stash is one of the two ways the user's work was left
 *  stashed with only a "checkout failed" to explain it. */
async function verifyCurrentBranch(projectPath: string, branch: string): Promise<void> {
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
}

/** Local (non-network) git in this module. Deliberately [runGitRemote] with no
 *  deadline rather than a bare spawn: its `LC_ALL=C` is what makes every prose
 *  matcher here — [parseStashSubject]'s `WIP on`/`On`, [isDirtyWorktreeRefusal]'s
 *  `would be overwritten by` — a fact rather than a guess about the user's
 *  locale, and `GIT_OPTIONAL_LOCKS=0` keeps a read from contending with the
 *  agent's own git for `index.lock`. */
async function runGit(
  cwd: string,
  args: string[],
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  return runGitRemote(cwd, args);
}

/** Internal to [checkoutLocalBranch]'s stash-and-retry path only — every other
 *  caller stashes by passing `stashIfDirty`, so there is exactly one place a
 *  stash is created here and exactly one message format for
 *  [parseStashSubject] to read back. */
async function stashPush(projectPath: string, message: string): Promise<StashEntry> {
  const { exitCode, stdout, stderr } = await runGit(projectPath, ["stash", "push", "-u", "-m", message]);
  if (exitCode !== 0) {
    throw new GitHelperError("STASH_FAILED", stderr.trim() || stdout.trim() || `git stash push exited ${exitCode}`);
  }
  const created = (await listStashes(projectPath))[0];
  if (!created) {
    // "No local changes to save" exits 0 with nothing pushed — reachable only
    // if the tree went clean between the DIRTY_WORKTREE refusal and here (a
    // concurrent commit/discard), not something this function can diagnose.
    throw new GitHelperError("STASH_FAILED", "git stash push reported success but created no stash");
  }
  return created;
}

/** Rollback path only, for when the retried switch fails anyway — swallows
 *  its own failure because the caller is already mid-throw over the ORIGINAL
 *  refusal, and a second, unrelated error here would bury it. Leaves the
 *  stash in place on failure, which is still recoverable from the Git panel. */
async function stashPopBestEffort(projectPath: string, ref: string): Promise<void> {
  await runGit(projectPath, ["stash", "pop", ref]).catch(() => undefined);
}

/** Every stash in the repository, most recent first — matches `git stash
 *  list`'s own order. Stashes are shared across every worktree of this
 *  repository (see [StashEntry]), so this is the same list regardless of
 *  which checkout `projectPath` names. */
export async function listStashes(projectPath: string): Promise<StashEntry[]> {
  // \x1f (unit separator) rather than a printable delimiter: a stash message
  // is free-form user/Antgrid text and could itself contain a tab or pipe.
  const { exitCode, stdout } = await runGit(projectPath, [
    "stash", "list", "--format=%gd\x1f%gs\x1f%at",
  ]);
  if (exitCode !== 0) return [];
  return stdout
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .map((line) => {
      const [ref, subject, at] = line.split("\x1f");
      const { branch, message } = parseStashSubject(subject ?? "");
      return { ref: ref ?? "", branch, message, createdAt: Number(at) || 0 };
    });
}

/** The only shape a stash reference may take on its way to argv — exactly what
 *  [listStashes] reports (git's own `%gd`), which is the only place the app
 *  ever gets one.
 *
 *  Same hazard [checkoutLocalBranch] refuses a leading `-` for, and reachable
 *  the same way: `parseMessageFast` validates the message TYPE alone on the
 *  encrypted/local hot path, so `git:stash-pop`/`-drop`'s Zod `ref` never runs
 *  and an arbitrary string arrives here POSITIONALLY. `git stash pop --index`
 *  pops `stash@{0}` — not the entry the user tapped — and restores the index
 *  with it; `git stash drop --help` opens git's help viewer, which under a
 *  non-interactive `Bun.spawn` never exits and hangs the handler forever. */
const STASH_REF_RE = /^stash@\{\d{1,9}\}$/;

function assertStashRef(ref: string): void {
  if (!STASH_REF_RE.test(ref)) {
    throw new GitHelperError("STASH_FAILED", `'${ref}' is not a stash reference`);
  }
}

/** Reapplies a stash and drops it on success — git's own `stash pop`, and the
 *  Restore affordance's whole meaning: "put it back", not "keep a copy too".
 *  A conflicting pop leaves the stash in the list, same as git itself, and is
 *  surfaced to the user as the ordinary working-tree conflict it now is
 *  rather than something this function tries to resolve or roll back. */
export async function stashPop(projectPath: string, ref: string): Promise<void> {
  assertStashRef(ref);
  const { exitCode, stdout, stderr } = await runGit(projectPath, ["stash", "pop", ref]);
  if (exitCode !== 0) {
    throw new GitHelperError("STASH_FAILED", stderr.trim() || stdout.trim() || `git stash pop ${ref} exited ${exitCode}`);
  }
}

export async function stashDrop(projectPath: string, ref: string): Promise<void> {
  assertStashRef(ref);
  const { exitCode, stderr } = await runGit(projectPath, ["stash", "drop", ref]);
  if (exitCode !== 0) {
    throw new GitHelperError("STASH_FAILED", stderr.trim() || `git stash drop ${ref} exited ${exitCode}`);
  }
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
