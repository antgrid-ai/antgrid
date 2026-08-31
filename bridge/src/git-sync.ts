import { runGitRemote, resolvePushTarget } from "./git-branches";

/**
 * Why a push or pull did not happen, in a vocabulary the app switches on for
 * copy. Deliberately a closed set: the app must never re-parse git's prose,
 * which is localized and reworded between versions — it forwards `stderr`
 * verbatim to the agent and branches its own UI on this.
 *
 * `unknown` is the honest answer for anything unrecognized, INCLUDING a
 * timeout. An app that meets a kind added by a newer bridge must read it as
 * `unknown` rather than failing (see `GitSyncFailureKind.fromWire` in the Dart
 * mirror), which is what lets this list grow without an app release.
 */
export type GitSyncFailureKind =
  | "no-remote"
  | "no-upstream"
  | "ambiguous-remote"
  | "not-fast-forward"
  | "rejected"
  | "diverged"
  | "auth"
  | "conflict"
  | "dirty-tree"
  | "detached"
  | "unknown";

export interface GitSyncResult {
  success: boolean;
  op: "push" | "pull";
  /** Current branch, or null on a detached HEAD. */
  branch: string | null;
  remote?: string;
  remoteBranch?: string;
  /** One line for a toast on success ("Pushed 3 commits to origin/main"). */
  summary?: string;
  error?: string;
  failureKind?: GitSyncFailureKind;
  /** The git invocation as run, for the agent handoff. Never a shell string —
   *  argv joined for reading, since nothing re-executes it. */
  command?: string;
  /** Git's own stderr, untouched. This is the half the agent actually needs. */
  stderr?: string;
}

/** Local-only view of how this branch stands against its upstream REF. Cheap
 *  enough to recompute on every git-status refresh precisely because it asks
 *  no remote — see [readSyncState]. */
export interface GitSyncState {
  branch: string | null;
  remote: string | null;
  remoteBranch: string | null;
  ahead: number;
  behind: number;
  hasUpstream: boolean;
  hasRemote: boolean;
}

export const EMPTY_SYNC_STATE: GitSyncState = {
  branch: null,
  remote: null,
  remoteBranch: null,
  ahead: 0,
  behind: 0,
  hasUpstream: false,
  hasRemote: false,
};

// A transfer has no UI deadline the way `ls-remote` does — the user has pressed
// a button and expects to wait — so this is a wedge guard, not a responsiveness
// one: a hung transport must not hold the checkout runtime forever. Generous
// enough that a genuinely large first push over a slow link still completes.
const TRANSFER_TIMEOUT_MS = 120_000;

/**
 * Classify a failed push/pull from git's own output.
 *
 * Pure, and separately exported, because every one of these strings is a real
 * one observed from a real git — a table test over them is the only way this
 * stays correct across git versions, and it cannot be written against a
 * function that also spawns processes.
 *
 * Order matters: a non-fast-forward rejection also contains the word
 * "rejected", and an auth failure over https also mentions the remote.
 */
export function classifySyncFailure(
  stderr: string,
  exitCode: number,
): GitSyncFailureKind {
  const s = stderr.toLowerCase();

  if (
    s.includes("could not read username")
    || s.includes("could not read password")
    || s.includes("authentication failed")
    || s.includes("permission denied (publickey")
    || s.includes("terminal prompts disabled")
    || s.includes("invalid username or token")
  ) {
    return "auth";
  }
  // `pull --ff-only` on a branch that has its own commits. Git's wording has
  // changed across versions ("Not possible to fast-forward" then
  // "Need to specify how to reconcile divergent branches"), hence both.
  if (
    s.includes("not possible to fast-forward")
    || s.includes("divergent branches")
    || s.includes("diverging branches")
  ) {
    return "diverged";
  }
  if (s.includes("non-fast-forward") || s.includes("fetch first")) {
    return "not-fast-forward";
  }
  if (s.includes("would be overwritten by merge") || s.includes("local changes")) {
    return "dirty-tree";
  }
  if (s.includes("conflict")) return "conflict";
  if (s.includes("has no upstream branch") || s.includes("no upstream configured")) {
    return "no-upstream";
  }
  // The URL sits between the two words ("repository 'https://…' not found"),
  // so this cannot be a substring test.
  if (s.includes("does not appear to be a git repository") || /repository .*not found/.test(s)) {
    return "no-remote";
  }
  if (s.includes("[rejected]") || s.includes("failed to push")) return "rejected";
  // 124 is the timeout sentinel [runGitRemote] returns; it is genuinely
  // unclassifiable — a hung auth prompt and a black-holed host look identical.
  if (exitCode === 124) return "unknown";
  return "unknown";
}

async function currentBranch(cwd: string): Promise<string | null> {
  const r = await runGitRemote(cwd, ["rev-parse", "--abbrev-ref", "HEAD"]);
  const name = r.stdout.trim();
  // `rev-parse --abbrev-ref` answers the literal "HEAD" when detached, which is
  // not a branch name and must not be handed to `push`/`pull` as one.
  if (r.exitCode !== 0 || !name || name === "HEAD") return null;
  return name;
}

/**
 * Ahead/behind against the upstream REF (`refs/remotes/...`), not against the
 * remote itself — deliberately the opposite trade-off from
 * [checkBranchAgainstRemote], and for a different job.
 *
 * This one rides every `git status` refresh, so it must cost nothing and reach
 * nothing: an `ls-remote` here would become one network round trip per checkout
 * every 10 seconds on the backstop poll alone. The counts it reports are
 * therefore as fresh as the last fetch — which is exactly the contract VS
 * Code's own ↑↓ indicator has, and pulling is what refreshes it. When the app
 * needs the truth it asks for a probe (`git:sync-status` with `probeRemote`),
 * and that path uses [checkBranchAgainstRemote].
 */
export async function readSyncState(cwd: string): Promise<GitSyncState> {
  const branch = await currentBranch(cwd);
  if (!branch) {
    // A detached HEAD still has remotes; reporting `hasRemote` lets the app say
    // "detached" rather than "no remote", which is a different fix.
    const remotes = await runGitRemote(cwd, ["remote"]);
    return {
      ...EMPTY_SYNC_STATE,
      hasRemote: remotes.exitCode === 0 && remotes.stdout.trim().length > 0,
    };
  }

  const target = await resolvePushTarget(cwd, branch);
  if (!target) return { ...EMPTY_SYNC_STATE, branch };

  // `@{upstream}` resolves only for a branch with tracking config AND a present
  // remote ref, which is precisely the condition for counts to mean anything.
  // Its failure is the `hasUpstream: false` signal — never an error.
  const counts = await runGitRemote(cwd, [
    "rev-list", "--left-right", "--count", `${branch}@{upstream}...${branch}`,
  ]);
  const base = {
    branch,
    remote: target.remote,
    remoteBranch: target.remoteBranch,
    hasRemote: true,
  };
  if (counts.exitCode !== 0) {
    return { ...base, ahead: 0, behind: 0, hasUpstream: false };
  }

  const [behindRaw, aheadRaw] = counts.stdout.trim().split(/\s+/);
  const behind = Number(behindRaw);
  const ahead = Number(aheadRaw);
  if (!Number.isFinite(behind) || !Number.isFinite(ahead)) {
    return { ...base, ahead: 0, behind: 0, hasUpstream: false };
  }
  return { ...base, ahead, behind, hasUpstream: true };
}

function fail(
  op: "push" | "pull",
  branch: string | null,
  kind: GitSyncFailureKind,
  error: string,
  extra: Partial<GitSyncResult> = {},
): GitSyncResult {
  return { success: false, op, branch, failureKind: kind, error, ...extra };
}

/**
 * Push the current branch, setting an upstream on a branch that has none.
 *
 * NEVER `--force` or `--force-with-lease`, under any failure. A force push is
 * an unrecoverable action the Handler takes a §5.2 snapshot before allowing
 * (`force_push` in `HandlerSnapshotWire`); it has no business behind a one-tap
 * control that a phone can reach. A rejected push returns the rejection intact
 * so the app can hand it to the agent, which reconciles it deliberately.
 */
export async function gitPush(cwd: string): Promise<GitSyncResult> {
  const branch = await currentBranch(cwd);
  if (!branch) {
    return fail("push", null, "detached", "HEAD is detached — check out a branch first");
  }

  const target = await resolvePushTarget(cwd, branch);
  if (!target) return fail("push", branch, "no-remote", "This repository has no remote");

  // `resolvePushTarget` falls back to same-name-on-origin for an untracked
  // branch, which is only a safe guess when there is one obvious remote. With
  // several and no `origin`, picking the first would publish the branch to
  // whichever remote sorted first — a wrong destination the user cannot undo.
  if (!target.tracked) {
    const remotes = await runGitRemote(cwd, ["remote"]);
    const names = remotes.stdout.split(/\r?\n/).map((n) => n.trim()).filter(Boolean);
    if (names.length > 1 && !names.includes("origin")) {
      return fail(
        "push",
        branch,
        "ambiguous-remote",
        `'${branch}' has no upstream and this repository has ${names.length} remotes`,
        { remote: target.remote, remoteBranch: target.remoteBranch },
      );
    }
  }

  const args = target.tracked
    ? ["push"]
    : ["push", "-u", target.remote, `${branch}:${target.remoteBranch}`];
  const res = await runGitRemote(cwd, args, TRANSFER_TIMEOUT_MS);
  const base = { op: "push" as const, branch, remote: target.remote, remoteBranch: target.remoteBranch };
  const command = `git ${args.join(" ")}`;

  if (res.exitCode !== 0) {
    const stderr = res.stderr.trim();
    return {
      ...base,
      success: false,
      failureKind: classifySyncFailure(stderr, res.exitCode),
      error: stderr || `git push exited ${res.exitCode}`,
      command,
      stderr,
    };
  }

  // "Everything up-to-date" is git's own wording and arrives on STDERR, which
  // is why success is decided by the exit code alone and this only picks copy.
  const upToDate = res.stderr.includes("Everything up-to-date");
  return {
    ...base,
    success: true,
    summary: upToDate
      ? "Already up to date"
      : `Pushed ${branch} to ${target.remote}/${target.remoteBranch}`,
    command,
  };
}

/**
 * Fetch, then fast-forward only.
 *
 * `--ff-only` is the whole safety property: a diverged branch leaves HEAD, the
 * index and the worktree byte-identical and reports `diverged`, instead of
 * merging (a merge commit nobody asked for) or rebasing (a repo left mid-rebase
 * with no UI able to finish it). Reconciling a diverged branch is exactly the
 * judgement call the agent handoff exists for.
 */
export async function gitPull(cwd: string): Promise<GitSyncResult> {
  const branch = await currentBranch(cwd);
  if (!branch) {
    return fail("pull", null, "detached", "HEAD is detached — check out a branch first");
  }

  const target = await resolvePushTarget(cwd, branch);
  if (!target) return fail("pull", branch, "no-remote", "This repository has no remote");

  const base = { op: "pull" as const, branch, remote: target.remote, remoteBranch: target.remoteBranch };

  // Checked BEFORE the fetch, not left to `pull` to refuse: git's own refusal
  // names the files it would clobber only sometimes, and this is the one
  // failure the user can act on without the agent (commit, or stash).
  const unmerged = await runGitRemote(cwd, ["ls-files", "--unmerged"]);
  if (unmerged.exitCode === 0 && unmerged.stdout.trim().length > 0) {
    return fail("pull", branch, "conflict", "Resolve the merge conflicts in this checkout first", base);
  }

  const fetchArgs = ["fetch", target.remote, target.remoteBranch];
  const fetched = await runGitRemote(cwd, fetchArgs, TRANSFER_TIMEOUT_MS);
  if (fetched.exitCode !== 0) {
    const stderr = fetched.stderr.trim();
    return {
      ...base,
      success: false,
      failureKind: classifySyncFailure(stderr, fetched.exitCode),
      error: stderr || `git fetch exited ${fetched.exitCode}`,
      command: `git ${fetchArgs.join(" ")}`,
      stderr,
    };
  }

  const before = await runGitRemote(cwd, ["rev-parse", "HEAD"]);
  const pullArgs = ["pull", "--ff-only"];
  const res = await runGitRemote(cwd, pullArgs, TRANSFER_TIMEOUT_MS);
  const command = `git ${pullArgs.join(" ")}`;

  if (res.exitCode !== 0) {
    const stderr = res.stderr.trim();
    return {
      ...base,
      success: false,
      failureKind: classifySyncFailure(stderr, res.exitCode),
      error: stderr || `git pull exited ${res.exitCode}`,
      command,
      stderr,
    };
  }

  const after = await runGitRemote(cwd, ["rev-parse", "HEAD"]);
  const moved = before.stdout.trim() !== after.stdout.trim();
  return {
    ...base,
    success: true,
    summary: moved
      ? `Updated ${branch} from ${target.remote}/${target.remoteBranch}`
      : "Already up to date",
    command,
  };
}
