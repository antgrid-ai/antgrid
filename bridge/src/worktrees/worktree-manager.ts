import { existsSync, realpathSync, statSync } from "node:fs";
import { readdir, rm } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import { resolveAbDir } from "../antgrid-dir";
import { CheckoutStore } from "./checkout-store";
import { isManagedCheckoutKind, type CheckoutRecord } from "./checkout-types";
import { parseWorktreeList } from "./git-worktree-list";
import { runGit, type GitRunner } from "./project-resolver";
import { logWorktreeEvent, worktreeErrorCode } from "./worktree-log";

/** Abbreviated on purpose. Every character in a managed checkout's path is one
 * the worktree's own deepest file cannot have: Windows still resolves most APIs
 * against a 260-char MAX_PATH, and a JS project's `node_modules` spends well
 * over half of that on its own. Same reason `shortCheckoutId` is not a UUID. */
const WORKTREE_ROOT_DIR = "wt";

/** How recently a directory under the worktree root may have been touched and
 * still be treated as a live create rather than an orphan. The project lock is
 * per-process, so a second bridge pointed at the same ANTGRID_DIR is the one
 * racer it cannot serialize; an orphan is by definition unreferenced, so
 * nothing writes into it and its mtime ages past this. */
const RECONCILE_GRACE_MS = 60_000;

/** Filesystem-safe, and a path segment before it is an identifier — 10 chars
 * against a UUID's 36. 40 bits of randomness, guarded by the existing
 * directory-exists check, which is ample for the handful of live checkouts a
 * machine ever holds. */
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
  | "WORKTREE_DELETE_FAILED";

export class WorktreeError extends Error {
  constructor(readonly code: WorktreeErrorCode, message: string) {
    super(message);
    this.name = "WorktreeError";
  }
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

function sessionSlug(name: string | undefined): string {
  const slug = (name ?? "session")
    .trim().toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^[.-]+|[.-]+$/g, "")
    .slice(0, 48);
  return slug || "session";
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
      const root = resolve(this.abDir, WORKTREE_ROOT_DIR, args.projectId);
      const worktreePath = resolve(root, checkoutId);
      if (!pathBelow(root, worktreePath)) {
        throw new WorktreeError("WORKTREE_CONFLICT", "The managed worktree path is outside Antgrid's worktree root.");
      }
      if (existsSync(worktreePath)) {
        throw new WorktreeError("WORKTREE_CONFLICT", "The managed worktree path already exists.");
      }

      const branch = await this.nextBranch(repoPath, sessionSlug(args.sessionName), args.sessionId);
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
    if (!exists) return { exists: false, registered, dirty: false, unpushedCommits: false, locked: false };
    const entry = list.exitCode === 0 ? parseWorktreeList(list.stdout)
      .find((item) => canonical(item.path) === canonical(record.path)) : undefined;
    const status = await this.git(["status", "--porcelain=v1", "--untracked-files=all"], record.path);
    const dirty = status.exitCode === 0 && status.stdout.trim().length > 0;
    // Commits reachable from the session branch but from nothing else — no
    // remote, and no other local branch. Everything after `--not` is negated,
    // so the branch itself MUST come first (`--branches --not … <branch>`
    // subtracts the very branch being asked about, and can never report
    // anything), and `--exclude` must precede the `--branches` it filters.
    const unpushed = record.branch
      ? (await this.git(
          ["rev-list", record.branch, "--not", "--remotes", "--exclude", record.branch, "--branches"],
          record.path,
        )).stdout.trim().length > 0
      : false;
    return { exists, registered, dirty, unpushedCommits: unpushed, locked: entry?.locked ?? false };
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
      const removed = await this.git(["worktree", "remove", ...(args.force ? ["--force"] : []), record.path], repoPath);
      if (removed.exitCode !== 0) throw new WorktreeError("WORKTREE_DELETE_FAILED", "Git could not remove the isolated worktree.");
    } else if (state.exists) {
      // An unregistered managed directory cannot safely be removed by Git.
      throw new WorktreeError("WORKTREE_DELETE_FAILED", "Git no longer recognizes the isolated worktree.");
    }
    const verified = await this.inspectRegistration(repoPath, record.path);
    if (verified) throw new WorktreeError("WORKTREE_DELETE_FAILED", "Git still reports the isolated worktree.");
    if (args.deleteBranch && record.branch) {
      const deleted = await this.git(["branch", "-D", record.branch], repoPath);
      if (deleted.exitCode !== 0) throw new WorktreeError("WORKTREE_DELETE_FAILED", "Git could not delete the isolated branch.");
    }
    await this.storeFor(record.projectId).remove(record.id);
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
    const wtRoot = resolve(this.abDir, WORKTREE_ROOT_DIR);
    const root = resolve(wtRoot, projectId);
    return this.withProjectLock(projectId, async () => {
      // The id reaches this from a control-plane verb, and the recursive delete
      // below must never be pointed outside our own state dir by a traversal
      // component.
      if (!pathBelow(wtRoot, root)) return { reclaimed: 0, stranded: 0, root };
      const startedAt = this.now();
      let repoPath: string | undefined;
      try { repoPath = this.repoPaths.get(projectId) ?? await this.options.resolveRepoPath?.(projectId); }
      catch { repoPath = undefined; }
      let records: CheckoutRecord[] = [];
      try {
        records = (await this.storeFor(projectId).list())
          .filter((record) => record.managed && isManagedCheckoutKind(record.kind));
      } catch { /* an unreadable store still leaves the blanket removal below */ }
      if (repoPath) {
        for (const record of records) {
          // `--force` twice on purpose: one still refuses a LOCKED worktree, and
          // `worktree prune` skips locked entries forever. A project being
          // forgotten is not a place to preserve a lock.
          await this.git(["worktree", "remove", "--force", "--force", record.path], repoPath).catch(() => undefined);
        }
      }
      // The common reason to forget a project is that its folder is already
      // gone, in which case Git can be asked nothing and blanket-removing our
      // own root is the only thing that reclaims the disk.
      await rm(root, { recursive: true, force: true }).catch(() => undefined);
      if (repoPath) await this.git(["worktree", "prune"], repoPath).catch(() => undefined);
      const stranded = (await readdir(root).catch(() => [])).length;
      logWorktreeEvent("worktree_forget_reclaimed", {
        projectId, reclaimed: records.length, stranded, elapsedMs: this.now() - startedAt,
      });
      // Branches are deliberately kept: they carry the user's commits, and
      // forgetting a project in Antgrid must never rewrite their repository.
      return { reclaimed: records.length, stranded, root };
    });
  }

  /** Drop checkout rows whose directory is gone and reclaim directories under
   * this project's worktree root that no row names. Never throws: it is
   * housekeeping on the side of work the caller actually asked for. */
  async reconcile(projectId: string, repoPath?: string): Promise<{ pruned: number; reclaimed: number }> {
    return this.withProjectLock(projectId, () => this.reconcileLocked(projectId, repoPath));
  }

  /** Counts ride in `counts` rather than the return value so a throw anywhere
   * inside still reports what was already done — and, more importantly, so the
   * create path this hangs off can never be failed by its own housekeeping. */
  private async reconcileLocked(projectId: string, repoPath?: string): Promise<{ pruned: number; reclaimed: number }> {
    const counts = { pruned: 0, reclaimed: 0 };
    try { await this.reconcileInner(projectId, repoPath, counts); } catch { /* housekeeping only */ }
    if (counts.pruned || counts.reclaimed) {
      // Only when something moved: a no-op reconcile must not add a line to
      // every isolated create.
      logWorktreeEvent("worktree_reconcile_completed", { projectId, ...counts });
    }
    return counts;
  }

  private async reconcileInner(
    projectId: string,
    repoPath: string | undefined,
    counts: { pruned: number; reclaimed: number },
  ): Promise<void> {
    const wtRoot = resolve(this.abDir, WORKTREE_ROOT_DIR);
    const root = resolve(wtRoot, projectId);
    if (!pathBelow(wtRoot, root)) return;
    // A directory the user deleted by hand leaves a registration behind, and
    // `worktree remove` refuses that path forever until the registration goes.
    if (repoPath) await this.git(["worktree", "prune"], repoPath).catch(() => undefined);

    const store = this.storeFor(projectId);
    const state = await store.read();
    const live = new Set<string>();
    for (const record of state.records) {
      if (!record.managed || existsSync(record.path)) {
        live.add(canonical(record.path));
        continue;
      }
      // A row is written only AFTER `worktree add` created the directory and
      // `verifyCreated` confirmed it, under the same project lock this holds —
      // so a row without a directory is always post-hoc loss, never a create in
      // flight. Left in place it makes its session permanently undeletable:
      // `remove()` can neither find the directory nor let Git drop it.
      if (await store.remove(record.id)) counts.pruned++;
    }

    // Everything above is safe on a partial read — its failure direction is
    // inaction. Everything below deletes on the strength of a checkout being
    // ABSENT from that read, so it may only run when the read was whole: a row
    // the file withheld names a LIVE worktree, and the store tolerating a bad
    // row exists precisely so one bad row cannot hide its healthy siblings.
    if (!state.healthy) return;

    for (const entry of await readdir(root).catch(() => [] as string[])) {
      const dir = resolve(root, entry);
      if (!pathBelow(root, dir) || live.has(canonical(dir))) continue;
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

  /** Whether a reclaim candidate holds work someone would miss. Reconciliation
   * rides on a create the user asked for and nothing else, so it must be at
   * least as reluctant as the explicit delete in `removeNow`, which refuses
   * WORKTREE_DIRTY. A genuine orphan comes straight out of `worktree add` and is
   * clean; a dirty one is a directory something has been working in, whatever
   * the metadata says. Git answering nothing means there is no checkout here to
   * lose. */
  private async hasLocalChanges(dir: string): Promise<boolean> {
    const status = await this.git(["status", "--porcelain=v1", "--untracked-files=all"], dir)
      .catch(() => undefined);
    return status?.exitCode === 0 && status.stdout.trim().length > 0;
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

  private async nextBranch(repoPath: string, slug: string, sessionId: string): Promise<string> {
    const stem = `antgrid/${slug}-${sessionId.replace(/[^a-zA-Z0-9]/g, "").slice(0, 8) || "session"}`;
    for (let suffix = 1; suffix < 10_000; suffix++) {
      const candidate = suffix === 1 ? stem : `${stem}-${suffix}`;
      const valid = await this.git(["check-ref-format", "--branch", candidate], repoPath);
      if (valid.exitCode !== 0) continue;
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
