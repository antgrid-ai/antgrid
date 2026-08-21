import { existsSync, realpathSync, statSync } from "node:fs";
import { readdir, rm, rmdir } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import { resolveAbDir } from "../antgrid-dir";
import { branchSlug, checkoutDirName, projectRootName, sessionWords } from "./checkout-names";
import { readCheckoutOwner, sameRepository } from "./checkout-owner";
import { CheckoutStore } from "./checkout-store";
import { isManagedCheckoutKind, type CheckoutRecord } from "./checkout-types";
import { parseWorktreeList } from "./git-worktree-list";
import { runGit, type GitRunner } from "./project-resolver";
import { logGitFailure, logWorktreeEvent, worktreeErrorCode } from "./worktree-log";

/** Abbreviated on purpose. Every character in a managed checkout's path is one
 * the worktree's own deepest file cannot have: Windows still resolves most APIs
 * against a 260-char MAX_PATH, and a JS project's `node_modules` spends well
 * over half of that on its own. Same reason the readable segments below it are
 * capped rather than spelled out in full (`checkout-names.ts`). */
const WORKTREE_ROOT_DIR = "wt";

/** How recently a directory under the worktree root may have been touched and
 * still be treated as a live create rather than an orphan. The project lock is
 * per-process, so a second bridge pointed at the same ANTGRID_DIR is the one
 * racer it cannot serialize; an orphan is by definition unreferenced, so
 * nothing writes into it and its mtime ages past this. */
const RECONCILE_GRACE_MS = 60_000;

/** How many same-stem branches to walk before giving up. A stem carries the
 * session's own word pair, so reaching even the low tens means something is
 * generating sessions in a loop — not a user naming things alike. */
const BRANCH_SUFFIX_MAX = 100;

/** 10 chars against a UUID's 36 — 40 bits of randomness, guarded by the
 * existing directory-exists check, which is ample for the handful of live
 * checkouts a machine ever holds. Only its tail reaches the directory name
 * (`checkoutDirName`); the whole id is the record key. */
function shortCheckoutId(): string {
  const bytes = new Uint8Array(5);
  // Called as a method: Web Crypto needs its Crypto receiver in Bun.
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export type WorktreeErrorCode =
  | "WORKTREE_UNSUPPORTED"
  | "NOT_GIT_REPOSITORY"
  | "UNKNOWN_BASE_BRANCH"
  | "WORKTREE_CONFLICT"
  | "WORKTREE_CREATE_FAILED"
  | "WORKTREE_WORKING_DIR_UNSAFE"
  | "WORKTREE_MISSING"
  | "WORKTREE_DIRTY"
  | "WORKTREE_UNPUSHED"
  | "WORKTREE_DELETE_FAILED"
  // Raised by SessionManager, not this file: the delete flag's lifetime must be
  // exactly one operation, so a second delete (or a start) against a session
  // already being removed is refused rather than allowed to race it. The app has
  // no copy arm for this code and falls through to `error.message`, so the text
  // must read as a sentence to the user.
  | "WORKTREE_DELETE_IN_PROGRESS";

export class WorktreeError extends Error {
  constructor(readonly code: WorktreeErrorCode, message: string) {
    super(message);
    this.name = "WorktreeError";
  }
}

/** `foreign` is not an error and not a no-op: it counts directories under our
 * own root that belong to ANOTHER repository, which is the only symptom two
 * projects sharing a root ever produces. */
export interface ReconcileCounts {
  pruned: number;
  reclaimed: number;
  foreign: number;
}

export interface WorktreeInspection {
  exists: boolean;
  registered: boolean;
  dirty: boolean;
  unpushedCommits: boolean;
  locked: boolean;
}

export interface PrepareWorktreeArgs {
  projectId: string;
  repoPath: string;
  sessionId: string;
  sessionName?: string;
  baseBranch?: string;
}

export interface RemoveWorktreeArgs {
  checkoutId: string;
  force: boolean;
  deleteBranch: boolean;
}

export interface WorktreeManagerOptions {
  abDir?: string;
  git?: GitRunner;
  checkoutStore?: (projectId: string) => CheckoutStore;
  newCheckoutId?: () => string;
  now?: () => number;
  /** Required after a bridge restart to remove a missing worktree registration. */
  resolveRepoPath?: (projectId: string) => Promise<string | undefined>;
}

function canonical(path: string): string {
  try { return realpathSync.native(path); } catch { return resolve(path); }
}

function pathBelow(root: string, target: string): boolean {
  const rel = relative(root, target);
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !rel.includes(`${sep}..${sep}`);
}

/** The sole owner of managed Git worktree lifecycle. Paths are derived here,
 * never accepted from a client or SessionManager. */
export class WorktreeManager {
  private static readonly creationLocks = new Map<string, Promise<void>>();
  private readonly abDir: string;
  private readonly git: GitRunner;
  private readonly storeFor: (projectId: string) => CheckoutStore;
  private readonly newCheckoutId: () => string;
  private readonly now: () => number;
  private readonly repoPaths = new Map<string, string>();

  constructor(private readonly options: WorktreeManagerOptions = {}) {
    this.abDir = options.abDir ?? resolveAbDir();
    this.git = options.git ?? runGit;
    this.storeFor = options.checkoutStore ?? ((projectId) => new CheckoutStore(this.abDir, projectId));
    this.newCheckoutId = options.newCheckoutId ?? shortCheckoutId;
    this.now = options.now ?? Date.now;
  }

  async prepareForSession(args: PrepareWorktreeArgs): Promise<CheckoutRecord> {
    // Outside the lock: the elapsed time a user experiences includes waiting
    // for a concurrent create on the same project.
    const startedAt = this.now();
    logWorktreeEvent("worktree_create_started", {
      projectId: args.projectId, sessionId: args.sessionId,
    });
    try {
      const record = await this.prepareLocked(args);
      logWorktreeEvent("worktree_create_succeeded", {
        projectId: args.projectId, sessionId: args.sessionId,
        checkoutId: record.id, elapsedMs: this.now() - startedAt,
      });
      return record;
    } catch (error) {
      logWorktreeEvent("worktree_create_failed", {
        projectId: args.projectId, sessionId: args.sessionId,
        elapsedMs: this.now() - startedAt, errorCode: worktreeErrorCode(error),
      });
      throw error;
    }
  }

  private async prepareLocked(args: PrepareWorktreeArgs): Promise<CheckoutRecord> {
    return this.withProjectLock(args.projectId, async () => {
      const repoPath = canonical(args.repoPath);
      this.repoPaths.set(args.projectId, repoPath);
      const listed = await this.git(["worktree", "list", "--porcelain", "-z"], repoPath);
      if (listed.exitCode !== 0) throw new WorktreeError("NOT_GIT_REPOSITORY", "This project is not a Git repository.");
      // Create time is the only moment that already holds the project lock, the
      // resolved repository and a reason to care that the tree is about to
      // grow. It runs AFTER the repository probe so a non-repository still
      // fails with NOT_GIT_REPOSITORY rather than on a reconcile symptom.
      await this.reconcileLocked(args.projectId, repoPath);

      const base = await this.resolveBase(repoPath, args.baseBranch);
      const checkoutId = this.newCheckoutId();
      const wtRoot = resolve(this.abDir, WORKTREE_ROOT_DIR);
      const root = resolve(wtRoot, projectRootName(repoPath, args.projectId));
      const worktreePath = resolve(root, checkoutDirName(args.sessionId, checkoutId));
      if (!pathBelow(wtRoot, root) || !pathBelow(root, worktreePath)) {
        throw new WorktreeError("WORKTREE_CONFLICT", "The managed worktree path is outside Antgrid's worktree root.");
      }
      if (existsSync(worktreePath)) {
        throw new WorktreeError("WORKTREE_CONFLICT", "The managed worktree path already exists.");
      }

      const branch = await this.nextBranch(repoPath, branchSlug(args.sessionName), sessionWords(args.sessionId));
      const add = await this.git(["worktree", "add", "--no-track", "-b", branch, worktreePath, base.commit], repoPath);
      if (add.exitCode !== 0) {
        throw new WorktreeError("WORKTREE_CREATE_FAILED", "Git could not create the isolated worktree.");
      }

      const record: CheckoutRecord = {
        id: checkoutId, projectId: args.projectId, kind: "managed-worktree",
        path: canonical(worktreePath), branch, baseRef: base.ref, managed: true,
        sessionId: args.sessionId, createdAt: this.now(),
      };
      try {
        await this.verifyCreated(repoPath, record, base.commit);
        await this.storeFor(args.projectId).put(record);
        return record;
      } catch (error) {
        await this.rollbackCreated(repoPath, record.path, branch, base.commit);
        if (error instanceof WorktreeError) throw error;
        throw new WorktreeError("WORKTREE_CREATE_FAILED", "Antgrid could not register the isolated worktree.");
      }
    });
  }

  /** The durable record for a checkout, or undefined when the project's store no
   * longer names it. A pure store read, deliberately separate from `inspect`:
   * that one answers "no such record" and "the project path is unavailable"
   * with the same WORKTREE_MISSING, and only the first means there is nothing
   * left to reclaim. */
  async recordFor(projectId: string, checkoutId: string): Promise<CheckoutRecord | undefined> {
    return this.storeFor(projectId).get(checkoutId);
  }

  async inspect(checkoutId: string): Promise<WorktreeInspection> {
    const located = await this.findCheckout(checkoutId);
    if (!located) throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree is no longer registered.");
    const { record, repoPath } = located;
    const list = await this.git(["worktree", "list", "--porcelain", "-z"], repoPath);
    const registered = list.exitCode === 0 && parseWorktreeList(list.stdout)
      .some((entry) => canonical(entry.path) === canonical(record.path));
    const exists = existsSync(record.path);
    // Asked of the REPOSITORY, not the checkout: `refs/heads` and `refs/remotes`
    // live in the common gitdir, so the answer survives a checkout directory
    // that is gone or unreadable. A missing directory is exactly when
    // `deleteBranch` would otherwise force-delete a branch whose unpushed
    // commits nothing ever checked.
    const unpushed = record.branch ? await this.hasUnpushedCommits(repoPath, record.branch) : false;
    if (!exists) return { exists: false, registered, dirty: false, unpushedCommits: unpushed, locked: false };
    const entry = list.exitCode === 0 ? parseWorktreeList(list.stdout)
      .find((item) => canonical(item.path) === canonical(record.path)) : undefined;
    const status = await this.git(["status", "--porcelain=v1", "--untracked-files=all"], record.path);
    // An unreadable status is not a clean one. `removeNow` now deletes the
    // directory itself whenever Git will not, so reading a failed `git status`
    // as "no local changes" is what would destroy them — a corrupt index or a
    // gitdir that moved out from under the checkout both answer non-zero while
    // the tree is still full of the user's work. Wreckage that has already lost
    // its `.git` link has nothing left to enumerate, and must stay deletable:
    // recovering those is the whole reason the reclaim exists.
    const dirty = status.exitCode !== 0
      ? existsSync(join(record.path, ".git"))
      : status.stdout.trim().length > 0;
    return { exists, registered, dirty, unpushedCommits: unpushed, locked: entry?.locked ?? false };
  }

  /** Commits reachable from the session branch but from nothing else — no
   * remote, and no other local branch. Everything after `--not` is negated, so
   * the branch itself MUST come first (`--branches --not <branch>` subtracts
   * the very branch being asked about, and can never report anything), and
   * `--exclude` must precede the `--branches` it filters.
   *
   * A failed rev-list is not "nothing to lose": it exits non-zero with an empty
   * stdout, which is byte-identical to the clean answer. The branch being GONE
   * is the one failure that really means nothing is at risk; every other one is
   * an unknown, and an unknown resolves to "there are commits" so the guard
   * refuses rather than opens. `force` remains the way past it. */
  private async hasUnpushedCommits(cwd: string, branch: string): Promise<boolean> {
    const listed = await this.git(
      ["rev-list", branch, "--not", "--remotes", "--exclude", branch, "--branches"],
      cwd,
    );
    if (listed.exitCode === 0) return listed.stdout.trim().length > 0;
    const present = await this.git(["show-ref", "--verify", "--quiet", `refs/heads/${branch}`], cwd);
    if (present.exitCode === 0) return true;
    // A branch that is GONE and a repository that cannot be read at all answer
    // `show-ref` identically, so the absence is only trustworthy once the
    // repository itself has been shown to still read. Anything else is the
    // unknown the doc above resolves to "there are commits".
    const readable = await this.git(["rev-parse", "--git-dir"], cwd);
    return readable.exitCode !== 0;
  }

  async remove(args: RemoveWorktreeArgs): Promise<void> {
    const startedAt = this.now();
    logWorktreeEvent("worktree_delete_started", { checkoutId: args.checkoutId });
    try {
      await this.removeNow(args);
      logWorktreeEvent("worktree_delete_succeeded", {
        checkoutId: args.checkoutId, elapsedMs: this.now() - startedAt,
      });
    } catch (error) {
      const code = worktreeErrorCode(error);
      // A refusal is a normal, recoverable outcome the user is about to be
      // asked about; only a genuine failure is reported as one.
      const blocked = code === "WORKTREE_DIRTY" || code === "WORKTREE_UNPUSHED" || code === "WORKTREE_CONFLICT";
      logWorktreeEvent(blocked ? "worktree_delete_blocked" : "worktree_delete_failed", {
        checkoutId: args.checkoutId, elapsedMs: this.now() - startedAt, errorCode: code,
      });
      throw error;
    }
  }

  private async removeNow(args: RemoveWorktreeArgs): Promise<void> {
    const located = await this.findCheckout(args.checkoutId);
    if (!located) throw new WorktreeError("WORKTREE_MISSING", "The isolated worktree is no longer registered.");
    const { record, repoPath } = located;
    if (!record.managed || !isManagedCheckoutKind(record.kind)) {
      throw new WorktreeError("WORKTREE_CONFLICT", "Antgrid does not own this checkout.");
    }
    const state = await this.inspect(args.checkoutId);
    if (state.locked && !args.force) throw new WorktreeError("WORKTREE_CONFLICT", "The isolated worktree is locked.");
    // Two codes, because the two losses are not the same: uncommitted work
    // vanishes with the directory, while unpushed commits survive on the branch
    // unless the user separately asks for the branch to go too.
    if (state.dirty && !args.force) {
      throw new WorktreeError("WORKTREE_DIRTY", "The isolated worktree has uncommitted changes.");
    }
    if (state.unpushedCommits && !args.force) {
      throw new WorktreeError("WORKTREE_UNPUSHED", "The isolated worktree's branch has unpushed commits.");
    }
    if (state.registered) {
      // `--force` twice, as in `reclaimForgottenProject`: one still refuses a
      // LOCKED worktree, and `worktree prune` skips locked entries forever — so
      // a single force would let the reclaim below delete the directory while
      // the registration survived, losing the tree AND still failing. The lock
      // was already answered above; force here means force.
      const forceArgs = args.force ? ["--force", "--force"] : [];
      const removed = await this.git(["worktree", "remove", ...forceArgs, record.path], repoPath);
      if (removed.exitCode !== 0) logGitFailure("worktree remove", removed);
    }
    // Git refusing, half-finishing, or no longer knowing the checkout all leave
    // the same wreckage: a directory that is ours, past guards the user has
    // already answered. Removing it here is not a second decision — it is the
    // one they just made, carried out by the only party left that can.
    //
    // Without this, a `worktree remove` that died partway was permanent: Git
    // deletes `.git` early in its sweep, so the next `worktree prune` reaped
    // the registration, and every retry then fell into an unregistered-but-
    // present branch that refused the directory forever.
    if (existsSync(record.path)) await this.reclaimOwnedPath(record, repoPath);
    if (existsSync(record.path)) {
      throw new WorktreeError("WORKTREE_DELETE_FAILED", "The isolated worktree's directory could not be removed.");
    }
    const verified = await this.inspectRegistration(repoPath, record.path);
    if (verified) throw new WorktreeError("WORKTREE_DELETE_FAILED", "Git still reports the isolated worktree.");
    // Past the point of no return: the worktree is gone and cannot be put back,
    // so nothing from here on may throw. A branch delete has two ordinary ways
    // to fail that are not our bug: the session renamed or deleted the branch,
    // and the user checked OUR branch out somewhere else, which Git refuses to
    // delete while that worktree holds it. Throwing on either left the store row
    // behind with no directory under it, which is the state that makes a session
    // undeletable forever.
    if (args.deleteBranch && record.branch) {
      const deleted = await this.git(["branch", "-D", record.branch], repoPath);
      if (deleted.exitCode !== 0) {
        logWorktreeEvent("worktree_delete_branch_kept", { checkoutId: record.id, projectId: record.projectId });
      }
    }
    await this.storeFor(record.projectId).remove(record.id);
  }

  /** The managed-checkout root. Nothing outside it may be deleted by anything
   * here that does not go through Git. */
  private worktreeRoot(): string {
    return resolve(this.abDir, WORKTREE_ROOT_DIR);
  }

  /** Delete a checkout directory ourselves, for the cases Git cannot finish.
   * Guarded on the path rather than on `record.managed`/`kind`: those are
   * metadata a hand-edited store can lie about, and this is the one check that
   * cannot be talked out of its answer.
   *
   * Best-effort by design — the caller re-tests the directory and reports the
   * failure, because whatever held it open is worth surfacing rather than
   * retrying blindly. */
  private async reclaimOwnedPath(record: CheckoutRecord, repoPath: string): Promise<void> {
    // Both sides through `canonical`, because the two are spelled differently
    // by construction: the root from `abDir` verbatim, `record.path` already
    // realpath-resolved when the row was written. Reach `abDir` through a
    // symlink — on macOS `/tmp` and `/var` both are — and the two spellings of
    // one directory stop comparing equal, so the guard would refuse every
    // checkout it exists to reclaim. Tests cannot see that on their own: they
    // build the checkout path from `abDir` too, so both sides agree by accident.
    if (!pathBelow(canonical(this.worktreeRoot()), canonical(record.path))) return;
    // Retries because the failure this exists to survive is a transient Windows
    // sharing violation: a scanner or a dying process can hold one file for a
    // few hundred milliseconds after `worktree remove` already gave up on it.
    await rm(record.path, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 }).catch(() => undefined);
    // The directory going away is what makes the registration prunable: Git
    // holds `.git/worktrees/<id>` until nothing claims it.
    if (!existsSync(record.path)) await this.git(["worktree", "prune"], repoPath).catch(() => undefined);
  }

  /** Undo a checkout which has been created but whose owning session failed to
   * commit. This intentionally bypasses the user-facing dirty/unpushed guard:
   * no agent was ever allowed to run in this checkout. Branch deletion remains
   * guarded by its creation commit. */
  async rollbackPrepared(record: CheckoutRecord): Promise<void> {
    const repoPath = this.repoPaths.get(record.projectId)
      ?? await this.options.resolveRepoPath?.(record.projectId);
    if (!repoPath) return;
    const headBefore = record.branch
      ? await this.git(["rev-parse", `refs/heads/${record.branch}^{commit}`], repoPath)
      : { exitCode: 1, stdout: "", stderr: "" };
    await this.git(["worktree", "remove", "--force", record.path], repoPath);
    const headAfter = record.branch
      ? await this.git(["rev-parse", `refs/heads/${record.branch}^{commit}`], repoPath)
      : { exitCode: 1, stdout: "", stderr: "" };
    if (record.branch && headBefore.exitCode === 0 && headAfter.exitCode === 0
      && headBefore.stdout.trim() === headAfter.stdout.trim()) {
      await this.git(["branch", "-D", record.branch], repoPath);
    }
    await this.storeFor(record.projectId).remove(record.id);
  }

  /** Reclaim every managed checkout of a project that is being forgotten, while
   * its metadata still exists. Deliberately force-removing and deliberately
   * partial: `forget()` deletes `agents/<id>/checkouts.json` immediately after,
   * so a refusal here would only leave a worktree nothing can ever name again.
   * `stranded` counts what survived — an entry left under our own root that Git
   * would not release. */
  async reclaimForgottenProject(projectId: string): Promise<{ reclaimed: number; stranded: number; root: string }> {
    const wtRoot = this.worktreeRoot();
    return this.withProjectLock(projectId, async () => {
      const startedAt = this.now();
      let repoPath: string | undefined;
      try { repoPath = this.repoPaths.get(projectId) ?? await this.options.resolveRepoPath?.(projectId); }
      catch { repoPath = undefined; }
      let records: CheckoutRecord[] = [];
      try {
        records = (await this.storeFor(projectId).list())
          .filter((record) => record.managed && isManagedCheckoutKind(record.kind));
      } catch { /* an unreadable store leaves only the ownership sweep below */ }
      // The id reaches this from a control-plane verb, and the recursive delete
      // below must never be pointed outside our own state dir by a traversal
      // component — `projectRoots` drops every candidate that is not under our
      // own root, which for such an id is all of them.
      const roots = this.projectRoots(wtRoot, projectId, repoPath, records);
      const root = roots[0] ?? resolve(wtRoot, projectId);
      if (roots.length === 0) return { reclaimed: 0, stranded: 0, root };
      // Read before anything is deleted: with the project folder already gone —
      // the common reason to forget one — a recorded checkout's `.git` pointer
      // is the last thing on the machine that says which repository these
      // directories belonged to.
      const ourCommonDir = await this.commonDirOf(repoPath, records);
      if (repoPath) {
        for (const record of records) {
          // `--force` twice on purpose: one still refuses a LOCKED worktree, and
          // `worktree prune` skips locked entries forever. A project being
          // forgotten is not a place to preserve a lock.
          await this.git(["worktree", "remove", "--force", "--force", record.path], repoPath).catch(() => undefined);
        }
      }
      // Per recorded path rather than a blanket removal of the root: two
      // projects whose folders share a name can hash into the same root, and a
      // blanket `rm` there destroys the OTHER project's uncommitted work while
      // reporting nothing stranded.
      let reclaimed = 0;
      for (const record of records) {
        await rm(record.path, { recursive: true, force: true }).catch(() => undefined);
        if (!existsSync(record.path)) reclaimed++;
      }
      // What no row named: ours to reclaim only if the directory says it is
      // ours. Anything else is left standing and counted. Counted into the same
      // total as the recorded paths — a project whose store was lost reclaims
      // entirely through this sweep, and reporting that as zero would read as a
      // no-op in the very log line written to explain the deletion.
      for (const { root: dir, entry } of await this.rootEntries(roots)) {
        const candidate = resolve(dir, entry);
        if (!pathBelow(dir, candidate) || !this.ownsCheckout(candidate, ourCommonDir)) continue;
        await rm(candidate, { recursive: true, force: true }).catch(() => undefined);
        if (!existsSync(candidate)) reclaimed++;
      }
      if (repoPath) await this.git(["worktree", "prune"], repoPath).catch(() => undefined);
      let stranded = 0;
      for (const dir of roots) {
        const left = await readdir(dir).catch(() => []);
        if (left.length === 0) await rmdir(dir).catch(() => undefined);
        stranded += left.length;
      }
      logWorktreeEvent("worktree_forget_reclaimed", {
        projectId, reclaimed, stranded, elapsedMs: this.now() - startedAt,
      });
      // Branches are deliberately kept: they carry the user's commits, and
      // forgetting a project in Antgrid must never rewrite their repository.
      return { reclaimed, stranded, root };
    });
  }

  /** Drop checkout rows whose directory is gone and reclaim directories under
   * this project's worktree root that no row names. Never throws: it is
   * housekeeping on the side of work the caller actually asked for. */
  async reconcile(projectId: string, repoPath?: string): Promise<ReconcileCounts> {
    return this.withProjectLock(projectId, () => this.reconcileLocked(projectId, repoPath));
  }

  /** Counts ride in `counts` rather than the return value so a throw anywhere
   * inside still reports what was already done — and, more importantly, so the
   * create path this hangs off can never be failed by its own housekeeping. */
  private async reconcileLocked(projectId: string, repoPath?: string): Promise<ReconcileCounts> {
    const counts: ReconcileCounts = { pruned: 0, reclaimed: 0, foreign: 0 };
    try { await this.reconcileInner(projectId, repoPath, counts); } catch { /* housekeeping only */ }
    if (counts.pruned || counts.reclaimed || counts.foreign) {
      // Only when something moved: a no-op reconcile must not add a line to
      // every isolated create. `foreign` is worth a line on its own — it means
      // two projects landed in one root, which nothing else on the machine
      // reports.
      logWorktreeEvent("worktree_reconcile_completed", { projectId, ...counts });
    }
    return counts;
  }

  private async reconcileInner(
    projectId: string,
    repoPath: string | undefined,
    counts: ReconcileCounts,
  ): Promise<void> {
    const wtRoot = this.worktreeRoot();
    // A directory the user deleted by hand leaves a registration behind, and
    // `worktree remove` refuses that path forever until the registration goes.
    if (repoPath) await this.git(["worktree", "prune"], repoPath).catch(() => undefined);

    const store = this.storeFor(projectId);
    const state = await store.read();
    // One listing for the whole sweep, read AFTER the prune above. `undefined`
    // means Git could not be asked at all, which must read as "every checkout
    // is live" — an empty set here would condemn all of them at once.
    const registered = await this.registeredPaths(repoPath);
    const live = new Set<string>();
    for (const record of state.records) {
      if (!record.managed) {
        live.add(canonical(record.path));
        continue;
      }
      // A row is written only AFTER `worktree add` created the directory and
      // `verifyCreated` confirmed it, under the same project lock this holds —
      // so a row without a directory is always post-hoc loss, never a create in
      // flight. Left in place it makes its session permanently undeletable:
      // `remove()` can neither find the directory nor let Git drop it.
      if (!existsSync(record.path)) {
        if (await store.remove(record.id)) counts.pruned++;
        continue;
      }
      // Present but stranded — the same permanent loss wearing the opposite
      // symptom, and the one this loop used to count as healthy purely because
      // the directory was still there. Dropping the row hands the session to
      // the same recovery a missing directory gets; the directory itself falls
      // through to the sweep below, which already owns the grace period and the
      // local-changes guard.
      if (this.isStranded(record, registered)) {
        if (await store.remove(record.id)) counts.pruned++;
        continue;
      }
      live.add(canonical(record.path));
    }

    // Everything above is safe on a partial read — its failure direction is
    // inaction. Everything below deletes on the strength of a checkout being
    // ABSENT from that read, so it may only run when the read was whole: a row
    // the file withheld names a LIVE worktree, and the store tolerating a bad
    // row exists precisely so one bad row cannot hide its healthy siblings.
    if (!state.healthy) return;

    const roots = this.projectRoots(wtRoot, projectId, repoPath, state.records);
    const ourCommonDir = await this.commonDirOf(repoPath, state.records);
    for (const { root, entry } of await this.rootEntries(roots)) {
      const dir = resolve(root, entry);
      if (!pathBelow(root, dir) || live.has(canonical(dir))) continue;
      // Asked first, and answered without spawning anything: a checkout another
      // project owns is not an orphan of ours, and the two checks below would
      // both clear it — `git status` reports a clean tree for a healthy foreign
      // worktree just as it does for one of our own.
      if (!this.ownsCheckout(dir, ourCommonDir)) { counts.foreign++; continue; }
      let mtimeMs: number;
      try { mtimeMs = statSync(dir).mtimeMs; } catch { continue; }
      if (this.now() - mtimeMs < RECONCILE_GRACE_MS) continue;
      if (await this.hasLocalChanges(dir)) continue;
      if (repoPath) await this.git(["worktree", "remove", "--force", "--force", dir], repoPath).catch(() => undefined);
      await rm(dir, { recursive: true, force: true }).catch(() => undefined);
      if (!existsSync(dir)) counts.reclaimed++;
    }
    if (repoPath && counts.reclaimed) await this.git(["worktree", "prune"], repoPath).catch(() => undefined);
  }

  /** Every directory this project's managed checkouts may live under. The
   * readable root name is derived from the repository FOLDER, so it cannot be
   * recomputed once that folder is gone — the parent of a recorded path is the
   * authority whenever there is one, and `wt/<projectId>` stays a candidate for
   * checkouts created before the readable naming landed. Filtering on
   * `pathBelow` here is what keeps a traversal component in a client-supplied
   * projectId out of the recursive deletes downstream. */
  private projectRoots(
    wtRoot: string,
    projectId: string,
    repoPath: string | undefined,
    records: CheckoutRecord[],
  ): string[] {
    const roots = new Set<string>();
    if (repoPath) roots.add(resolve(wtRoot, projectRootName(repoPath, projectId)));
    for (const record of records) {
      if (record.managed && isManagedCheckoutKind(record.kind)) roots.add(resolve(record.path, ".."));
    }
    roots.add(resolve(wtRoot, projectId));
    return [...roots].filter((root) => pathBelow(wtRoot, root));
  }

  /** Whether a directory under our worktree root is this project's to delete.
   * A directory holding no checkout at all is: it can only be a `git worktree
   * add` we interrupted, since nothing else writes here. A checkout belonging
   * to another repository is emphatically not, and neither is a full clone. */
  private ownsCheckout(dir: string, ourCommonDir: string | undefined): boolean {
    const owner = readCheckoutOwner(dir);
    if (owner.kind === "none") return true;
    // `unknown` with `repository`: a pointer we could not read proves nothing,
    // and every caller here is about to delete what this says is ours.
    if (owner.kind === "repository" || owner.kind === "unknown") return false;
    return ourCommonDir !== undefined && sameRepository(owner.commonDir, ourCommonDir);
  }

  /** This project's Git common directory — `<repo>/.git` for an ordinary
   * repository, elsewhere entirely for a `--separate-git-dir` one, which is why
   * Git is asked rather than the path assumed. Falls back to a recorded
   * checkout's own pointer so a project whose folder has already been deleted
   * can still recognise its own leftovers; undefined means nothing under the
   * root can be proven ours, and the sweeps then refuse to delete anything that
   * holds a checkout. */
  private async commonDirOf(repoPath: string | undefined, records: CheckoutRecord[]): Promise<string | undefined> {
    if (repoPath) {
      const found = await this.git(["rev-parse", "--git-common-dir"], repoPath).catch(() => undefined);
      const value = found?.exitCode === 0 ? found.stdout.trim() : "";
      if (value) return resolve(repoPath, value);
      return join(repoPath, ".git");
    }
    for (const record of records) {
      const owner = readCheckoutOwner(record.path);
      if (owner.kind === "worktree") return owner.commonDir;
    }
    return undefined;
  }

  private async rootEntries(roots: string[]): Promise<Array<{ root: string; entry: string }>> {
    const found: Array<{ root: string; entry: string }> = [];
    for (const root of roots) {
      for (const entry of await readdir(root).catch(() => [] as string[])) found.push({ root, entry });
    }
    return found;
  }

  /** Every worktree path this repository still registers, or `undefined` when
   * Git could not be asked. The distinction is the whole point: callers treat
   * `undefined` as "assume everything is live", because an empty set and an
   * unanswered question look identical and only one of them means the
   * checkouts are gone. */
  private async registeredPaths(repoPath: string | undefined): Promise<Set<string> | undefined> {
    if (!repoPath) return undefined;
    const list = await this.git(["worktree", "list", "--porcelain", "-z"], repoPath).catch(() => undefined);
    if (!list || list.exitCode !== 0) return undefined;
    return new Set(parseWorktreeList(list.stdout).map((entry) => canonical(entry.path)));
  }

  /** Whether a checkout's directory survives as wreckage rather than as a
   * working tree: Git no longer registers it AND it has no `.git` link at all.
   *
   * Both signals are required, and the second is what makes this safe to act
   * on. A `worktree remove` that dies partway deletes `.git` early in its sweep,
   * so a later prune reaps the entry it pointed at and leaves a tree no Git
   * command will touch again — that shape is unmistakable. A checkout someone
   * is still working in keeps its `.git` link however odd its registration
   * looks, so it can never reach this arm. */
  private isStranded(record: CheckoutRecord, registered: Set<string> | undefined): boolean {
    if (!registered || registered.has(canonical(record.path))) return false;
    return !existsSync(join(record.path, ".git"));
  }

  /** Whether a reclaim candidate holds work someone would miss. Reconciliation
   * rides on a create the user asked for and nothing else, so it must be at
   * least as reluctant as the explicit delete in `removeNow`, which refuses
   * WORKTREE_DIRTY. A genuine orphan comes straight out of `worktree add` and is
   * clean; a dirty one is a directory something has been working in, whatever
   * the metadata says.
   *
   * An unreadable status is not a clean one, exactly as in [inspect] — and this
   * path is the automatic one, so it has to be the more reluctant of the two. A
   * corrupt index, a gitdir that moved, or a transient lock all answer non-zero
   * over a tree still full of the user's work; the `.git` link is what separates
   * that from the wreckage this sweep exists to reclaim, which has none. */
  private async hasLocalChanges(dir: string): Promise<boolean> {
    const status = await this.git(["status", "--porcelain=v1", "--untracked-files=all"], dir)
      .catch(() => undefined);
    if (!status || status.exitCode !== 0) return existsSync(join(dir, ".git"));
    return status.stdout.trim().length > 0;
  }

  private async resolveBase(repoPath: string, baseBranch?: string): Promise<{ ref: string | null; commit: string }> {
    if (baseBranch) {
      const branches = await this.git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], repoPath);
      if (branches.exitCode !== 0 || !branches.stdout.split(/\r?\n/).map((name) => name.trim()).includes(baseBranch)) {
        throw new WorktreeError("UNKNOWN_BASE_BRANCH", "The selected base branch no longer exists.");
      }
      const commit = await this.git(["rev-parse", `refs/heads/${baseBranch}^{commit}`], repoPath);
      if (commit.exitCode !== 0 || !commit.stdout.trim()) throw new WorktreeError("UNKNOWN_BASE_BRANCH", "The selected base branch no longer exists.");
      return { ref: baseBranch, commit: commit.stdout.trim() };
    }
    const head = await this.git(["rev-parse", "HEAD^{commit}"], repoPath);
    if (head.exitCode !== 0 || !head.stdout.trim()) throw new WorktreeError("WORKTREE_CREATE_FAILED", "The main checkout has no commit to use as a base.");
    return { ref: null, commit: head.stdout.trim() };
  }

  /** The session's name for reading and its word pair for identity — the pair
   * being the only thing that ties a branch to the directory it is checked out
   * into, now that the directory is no longer named after the session.
   *
   * Format is settled ONCE and existence in the loop, because they are not the
   * same kind of problem: a stem Git refuses is refused however many suffixes
   * are appended to it. Deciding both inside the loop cost 9999 process spawns
   * — measured at ~3.6 minutes, holding the project lock — before failing a
   * session whose name merely contained `..`. The fallback needs no second
   * check: a word pair is letters and one hyphen. */
  private async nextBranch(repoPath: string, slug: string, words: string): Promise<string> {
    const preferred = slug ? `antgrid/${slug}-${words}` : `antgrid/${words}`;
    const valid = await this.git(["check-ref-format", "--branch", preferred], repoPath);
    const stem = valid.exitCode === 0 ? preferred : `antgrid/${words}`;
    for (let suffix = 1; suffix <= BRANCH_SUFFIX_MAX; suffix++) {
      const candidate = suffix === 1 ? stem : `${stem}-${suffix}`;
      const exists = await this.git(["show-ref", "--verify", "--quiet", `refs/heads/${candidate}`], repoPath);
      if (exists.exitCode !== 0) return candidate;
    }
    throw new WorktreeError("WORKTREE_CONFLICT", "Could not choose a unique branch name for the isolated worktree.");
  }

  private async verifyCreated(repoPath: string, record: CheckoutRecord, commit: string): Promise<void> {
    const list = await this.git(["worktree", "list", "--porcelain", "-z"], repoPath);
    const verified = list.exitCode === 0 && parseWorktreeList(list.stdout).some((entry) =>
      canonical(entry.path) === canonical(record.path) && entry.branch === `refs/heads/${record.branch}` && entry.head === commit,
    );
    if (!verified) throw new WorktreeError("WORKTREE_CONFLICT", "Git did not register the new isolated worktree as expected.");
  }

  private async rollbackCreated(repoPath: string, path: string, branch: string, commit: string): Promise<void> {
    await this.git(["worktree", "remove", "--force", path], repoPath);
    const head = await this.git(["rev-parse", `refs/heads/${branch}^{commit}`], repoPath);
    if (head.exitCode === 0 && head.stdout.trim() === commit) await this.git(["branch", "-D", branch], repoPath);
  }

  private async findCheckout(checkoutId: string): Promise<{ record: CheckoutRecord; repoPath: string } | undefined> {
    for (const [projectId, repoPath] of this.repoPaths) {
      const record = await this.storeFor(projectId).get(checkoutId);
      if (record) return { record, repoPath };
    }
    // This keeps inspection/removal durable over a restart when the caller
    // provides the project catalogue resolver used by HostServer later on.
    try {
      for (const projectId of await readdir(join(this.abDir, "agents"))) {
        const record = await this.storeFor(projectId).get(checkoutId);
        if (!record) continue;
        const repoPath = this.repoPaths.get(projectId) ?? await this.options.resolveRepoPath?.(projectId);
        if (!repoPath) throw new WorktreeError("WORKTREE_MISSING", "The project path for this isolated worktree is unavailable.");
        this.repoPaths.set(projectId, repoPath);
        return { record, repoPath };
      }
    } catch (error) {
      if (error instanceof WorktreeError) throw error;
    }
    return undefined;
  }

  private async inspectRegistration(repoPath: string, path: string): Promise<boolean> {
    const list = await this.git(["worktree", "list", "--porcelain", "-z"], repoPath);
    return list.exitCode === 0 && parseWorktreeList(list.stdout).some((entry) => canonical(entry.path) === canonical(path));
  }

  private async withProjectLock<T>(projectId: string, fn: () => Promise<T>): Promise<T> {
    const previous = WorktreeManager.creationLocks.get(projectId) ?? Promise.resolve();
    let release!: () => void;
    const mine = new Promise<void>((resolve) => { release = resolve; });
    const queued = previous.then(() => mine);
    WorktreeManager.creationLocks.set(projectId, queued);
    await previous;
    try { return await fn(); }
    finally {
      release();
      if (WorktreeManager.creationLocks.get(projectId) === queued) WorktreeManager.creationLocks.delete(projectId);
    }
  }
}
