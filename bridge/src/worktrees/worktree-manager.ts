import { existsSync, realpathSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";
import { resolveAbDir } from "../antgrid-dir";
import { CheckoutStore } from "./checkout-store";
import type { CheckoutRecord } from "./checkout-types";
import { parseWorktreeList } from "./git-worktree-list";
import { runGit, type GitRunner } from "./project-resolver";
import { logWorktreeEvent, worktreeErrorCode } from "./worktree-log";

/** Abbreviated on purpose. Every character in a managed checkout's path is one
 * the worktree's own deepest file cannot have: Windows still resolves most APIs
 * against a 260-char MAX_PATH, and a JS project's `node_modules` spends well
 * over half of that on its own. Same reason `shortCheckoutId` is not a UUID. */
const WORKTREE_ROOT_DIR = "wt";

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
      await this.git(["worktree", "prune"], repoPath); // best effort only

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
    if (!record.managed || record.kind !== "managed-worktree") {
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
