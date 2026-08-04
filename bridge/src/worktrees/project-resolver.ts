import { realpathSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { computeProjectId } from "../project-id";
import { parseWorktreeList } from "./git-worktree-list";

const MAX_GIT_OUTPUT_BYTES = 1024 * 1024;

export interface ResolvedProject {
  projectId: string;
  repoPath: string;
  selectedPath: string;
  isGitRepository: boolean;
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

/** Resolve a user-selected folder to its repository's primary checkout.
 * Non-Git folders deliberately retain the pre-worktree path-hash identity. */
export async function resolveProject(folder: string, git: GitRunner = runGit): Promise<ResolvedProject> {
  const selectedPath = canonicalPath(folder);
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
    };
  }

  const worktrees = parseWorktreeList(list.stdout);
  const primary = worktrees.find((worktree) => !worktree.bare);
  if (primary) {
    return {
      projectId: computeProjectId(primary.path),
      repoPath: primary.path,
      selectedPath,
      isGitRepository: true,
    };
  }

  // Bare repositories have no usable checkout. The common Git dir is stable
  // for every linked checkout, so it is the least surprising repository key.
  const commonDir = await run(["rev-parse", "--git-common-dir"]);
  const rawDir = commonDir.exitCode === 0 ? commonDir.stdout.trim() : selectedPath;
  const commonPath = canonicalPath(isAbsolute(rawDir) ? rawDir : resolve(selectedPath, rawDir));
  return {
    projectId: computeProjectId(commonPath),
    repoPath: commonPath,
    selectedPath,
    isGitRepository: true,
  };
}
