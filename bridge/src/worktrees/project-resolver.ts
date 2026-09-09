import { realpathSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { resolveAbDir } from "../antgrid-dir";
import { computeProjectId } from "../project-id";
import { normalizeRepoKey } from "../repo-key";
import { CheckoutStore } from "./checkout-store";
import { parseWorktreeList } from "./git-worktree-list";
import { pathBelow } from "./path-guard";

const MAX_GIT_OUTPUT_BYTES = 1024 * 1024;

// Mirrors WorktreeManager's own WORKTREE_ROOT_DIR (worktree-manager.ts), which
// is not exported — only the literal is shared, deliberately, so this module
// never needs a WorktreeManager instance just to ask "is this folder managed".
const WORKTREE_ROOT_DIR = "wt";

export type ResolvedProjectKind = "primary" | "managed-checkout" | "linked-worktree" | "plain";

export interface ResolvedProject {
  projectId: string;
  repoPath: string;
  selectedPath: string;
  isGitRepository: boolean;
  kind: ResolvedProjectKind;
  /** Set only for a "managed-checkout" whose checkouts.json still names it. */
  checkoutId?: string;
  /** Cross-machine repository identity, or `null` when this folder names no
   *  shareable repository. Callers mint a synthetic per-machine key from it —
   *  never a guess (see repo-key.ts). */
  repoKey: string | null;
}

export interface GitCommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export type GitRunner = (args: string[], cwd: string) => Promise<GitCommandResult>;

function canonicalPath(path: string): string {
  try { return realpathSync.native(path); } catch { return resolve(path); }
}

async function readBounded(stream: ReadableStream<Uint8Array> | null): Promise<string> {
  if (!stream) return "";
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      size += next.value.byteLength;
      if (size > MAX_GIT_OUTPUT_BYTES) throw new Error("git output exceeded limit");
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const out = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { out.set(chunk, offset); offset += chunk.byteLength; }
  return new TextDecoder().decode(out);
}

export const runGit: GitRunner = async (args, cwd) => {
  // A spawn that never starts is reported as a failed command, never thrown:
  // `git` missing from PATH and a cwd that no longer exists both make
  // Bun.spawn throw synchronously, and every caller here already treats a
  // non-zero exit as "not a repository". Letting it reject instead would make
  // HostServer.open — which resolves before anything else — fail for plain
  // non-Git projects on a machine without Git.
  try {
    const proc = Bun.spawn(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, exitCode] = await Promise.all([
      readBounded(proc.stdout),
      readBounded(proc.stderr),
      proc.exited,
    ]);
    return { exitCode, stdout, stderr };
  } catch (error) {
    // Covers the output cap too: a repository whose `git` answer is too large to
    // read is no more usable than one we could not ask.
    return { exitCode: -1, stdout: "", stderr: error instanceof Error ? error.message : String(error) };
  }
};

/** Every project whose store claims `selectedPath`, sorted by projectId so a
 * path two stores both name resolves the same way on every machine. Empty when
 * none does — including when the stores cannot be read at all. A hand-edited or
 * corrupt checkouts.json must never turn a fold into a thrown error; it just
 * means the fold reports no owner. */
async function findCheckoutOwners(
  abDir: string,
  selectedPath: string,
): Promise<Array<{ projectId: string; checkoutId: string }>> {
  let projectIds: string[];
  try { projectIds = await readdir(join(abDir, "agents")); }
  catch { return []; }
  const owners: Array<{ projectId: string; checkoutId: string }> = [];
  for (const projectId of projectIds.sort()) {
    try {
      // `list()` drops rows whose projectId disagrees with the directory, so a
      // row cannot name a project other than the one whose store holds it.
      const records = await new CheckoutStore(abDir, projectId).list();
      const match = records.find((record) => canonicalPath(record.path) === selectedPath);
      if (match) owners.push({ projectId, checkoutId: match.id });
    } catch { continue; }
  }
  return owners;
}

/** Resolve a user-selected folder to its repository identity.
 * Non-Git folders deliberately retain the pre-worktree path-hash identity. */
export async function resolveProject(
  folder: string,
  git: GitRunner = runGit,
  opts?: { abDir?: string },
): Promise<ResolvedProject> {
  const selectedPath = canonicalPath(folder);
  const abDir = opts?.abDir ?? resolveAbDir();
  // A runner that fails to run at all is the same answer as one that ran and
  // said no: not a repository. This function is the FIRST thing HostServer.open
  // does, so a rejection here would fail every project open on the machine —
  // including for folders that have nothing to do with Git.
  const run = async (args: string[]): Promise<GitCommandResult> => {
    try { return await git(args, selectedPath); }
    catch (error) {
      return { exitCode: -1, stdout: "", stderr: error instanceof Error ? error.message : String(error) };
    }
  };
  const list = await run(["worktree", "list", "--porcelain", "-z"]);
  if (list.exitCode !== 0) {
    return {
      projectId: computeProjectId(selectedPath),
      repoPath: selectedPath,
      selectedPath,
      isGitRepository: false,
      kind: "plain",
      repoKey: null,
    };
  }

  // `origin` only: identity has to be the one remote every clone of a repository
  // agrees on, and a fork's `upstream` would merge two repositories into one key.
  // A repo without one is indistinguishable here from a git we could not ask,
  // and both answer "no shareable identity" rather than failing the resolve.
  const origin = await run(["remote", "get-url", "origin"]);
  const repoKey = origin.exitCode === 0 ? normalizeRepoKey(origin.stdout.trim()) : null;

  const worktrees = parseWorktreeList(list.stdout).filter((worktree) => !worktree.bare);
  const primaryRaw = worktrees[0];
  if (primaryRaw) {
    const primaryPath = canonicalPath(primaryRaw.path);
    // `git worktree list` ran rooted at selectedPath, so selectedPath is
    // necessarily inside one of these entries — possibly several levels below
    // its root (an ordinary subdirectory, not a worktree of its own). The
    // deepest containing entry is the one whose identity selectedPath
    // inherits; falling back to the primary covers the case where none
    // contains it (shouldn't happen, but must never invent a fresh identity).
    const worktreePaths = worktrees.map((worktree) => canonicalPath(worktree.path));
    const matchedPath = worktreePaths
      .filter((path) => path === selectedPath || pathBelow(path, selectedPath))
      .sort((a, b) => b.length - a.length)[0] ?? primaryPath;

    if (matchedPath === primaryPath) {
      return {
        projectId: computeProjectId(primaryPath),
        repoPath: primaryPath,
        selectedPath,
        isGitRepository: true,
        kind: "primary",
        repoKey,
      };
    }
    const wtRoot = canonicalPath(resolve(abDir, WORKTREE_ROOT_DIR));
    if (pathBelow(wtRoot, matchedPath)) {
      // A checkout Antgrid created for an isolated session: fold to the owning
      // project's identity, so an isolated session's tree/git/search all read
      // the ONE project.
      //
      // The owner is whichever project the session was started FROM, which is
      // not always the primary: start an isolated session inside a linked
      // worktree the user made, and `git worktree list` still names the primary
      // — so folding there opens a project whose store has no record of this
      // checkout, i.e. the wrong row with no checkout to focus. Only the stores
      // know, so ask them.
      //
      // Adopted only when the owner's own root is one of these worktrees:
      // every kind this function returns keeps
      // `projectId === computeProjectId(repoPath)`, and `HostServer.open`
      // refuses a pair that breaks it. An owner whose folder is gone therefore
      // falls back to the primary rather than naming a repoPath that hashes to
      // something else.
      const owners = await findCheckoutOwners(abDir, selectedPath);
      const owned = owners
        .map((owner) => ({
          ...owner,
          repoPath: worktreePaths.find((path) => computeProjectId(path) === owner.projectId),
        }))
        .find((owner) => owner.repoPath !== undefined);
      if (owned?.repoPath !== undefined) {
        return {
          projectId: owned.projectId,
          repoPath: owned.repoPath,
          selectedPath,
          isGitRepository: true,
          kind: "managed-checkout",
          checkoutId: owned.checkoutId,
          repoKey,
        };
      }
      return {
        projectId: computeProjectId(primaryPath),
        repoPath: primaryPath,
        selectedPath,
        isGitRepository: true,
        kind: "managed-checkout",
        repoKey,
      };
    }
    // A worktree the USER made (outside Antgrid's own root): folding it to the
    // primary would hand its own files to the primary's project, so it gets an
    // identity of its own instead — keyed by the worktree's own root, not by
    // whatever subdirectory of it was selected.
    return {
      projectId: computeProjectId(matchedPath),
      repoPath: matchedPath,
      selectedPath,
      isGitRepository: true,
      kind: "linked-worktree",
      repoKey,
    };
  }

  // Bare repositories have no usable checkout. The common Git dir is stable
  // for every linked checkout, so it is the least surprising repository key.
  // Keyed by common dir rather than split into its own kind: a bare repo has
  // no worktree to distinguish "primary" from at all.
  const commonDir = await run(["rev-parse", "--git-common-dir"]);
  const rawDir = commonDir.exitCode === 0 ? commonDir.stdout.trim() : selectedPath;
  const commonPath = canonicalPath(isAbsolute(rawDir) ? rawDir : resolve(selectedPath, rawDir));
  return {
    projectId: computeProjectId(commonPath),
    repoPath: commonPath,
    selectedPath,
    isGitRepository: true,
    kind: "primary",
    repoKey,
  };
}
