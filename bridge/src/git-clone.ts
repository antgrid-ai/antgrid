import { existsSync, rmSync, statSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { runGitRemote } from "./git-branches";

/** Cloning a large repo over a slow link is legitimately minutes, unlike the
 *  UI-bound probes `runGitRemote` is otherwise given a few seconds for. */
const CLONE_TIMEOUT_MS = 10 * 60_000;

export class GitCloneError extends Error {
  constructor(
    readonly code: "BAD_URL" | "BAD_TARGET" | "TARGET_EXISTS" | "CLONE_FAILED",
    message: string,
  ) {
    super(message);
  }
}

// Only network transports. `ext::` and `file://` run a command or read a local
// path on behalf of whoever named the URL, and a leading `-` would reach git as
// an option.
const CLONE_URL = /^(https:\/\/|ssh:\/\/|git@)[^\s]+$/;

const DIR_NAME = /^[A-Za-z0-9._-]+$/;

export function isCloneableUrl(url: string): boolean {
  return CLONE_URL.test(url) && !url.startsWith("-");
}

/** `ssh -o BatchMode=yes`, so a private repo with no cached credential fails
 *  fast instead of hanging the clone on a passphrase or host-key prompt that
 *  nothing here has a terminal to answer. Never clobbers an operator's own
 *  `GIT_SSH_COMMAND` (a wrapper script may already be handling auth its own
 *  way) — leaving that case alone is the whole preservation this does; it does
 *  not also check `core.sshCommand`, which would need a config probe of its
 *  own. */
export function cloneSshEnv(): Record<string, string | undefined> | undefined {
  return process.env.GIT_SSH_COMMAND ? undefined : { GIT_SSH_COMMAND: "ssh -o BatchMode=yes" };
}

/** Last path segment of a clone URL without `.git` — the folder git itself
 *  would pick. */
export function defaultCloneDirName(url: string): string | null {
  const tail = url.replace(/\/+$/, "").split(/[/:]/).pop() ?? "";
  const name = tail.replace(/\.git$/, "");
  return DIR_NAME.test(name) && name !== "." && name !== ".." ? name : null;
}

/**
 * `git clone <url>` into `<parentDir>/<dirName>`; returns the new checkout path.
 *
 * Never overwrites: an existing target is refused rather than cloned into, so a
 * misclick cannot mix a repository into a folder that already holds someone's
 * work.
 */
export async function cloneRepository(args: {
  url: string;
  parentDir: string;
  dirName?: string;
  /** TEST SEAM: override the network deadline so the kill-mid-clone cleanup
   *  path can be exercised without a real 10-minute wait. Production callers
   *  never set this. */
  timeoutMs?: number;
}): Promise<string> {
  const { url, parentDir } = args;
  if (!isCloneableUrl(url)) {
    throw new GitCloneError("BAD_URL", "Only https, ssh and git@ repository URLs can be cloned.");
  }
  // A relative parentDir resolves against whatever the host process's cwd
  // happens to be at call time — not a folder the caller actually chose.
  if (!isAbsolute(parentDir)) {
    throw new GitCloneError("BAD_TARGET", "The parent folder must be an absolute path.");
  }
  const dirName = args.dirName ?? defaultCloneDirName(url);
  if (!dirName || !DIR_NAME.test(dirName) || dirName === "." || dirName === "..") {
    throw new GitCloneError("BAD_TARGET", "Could not derive a folder name for this repository.");
  }
  if (!existsSync(parentDir) || !statSync(parentDir).isDirectory()) {
    throw new GitCloneError("BAD_TARGET", "The chosen parent folder does not exist.");
  }
  const target = join(parentDir, dirName);
  if (existsSync(target)) {
    throw new GitCloneError("TARGET_EXISTS", `${target} already exists.`);
  }

  // `--` ends option parsing so the URL can never be read as a flag.
  const r = await runGitRemote(parentDir, ["clone", "--", url, dirName], args.timeoutMs ?? CLONE_TIMEOUT_MS, cloneSshEnv());
  if (r.exitCode !== 0) {
    const reason = r.stderr.trim().split("\n").pop() || `git clone exited ${r.exitCode}`;
    // The TARGET_EXISTS check above proved this path was empty when the clone
    // started, so anything left here after a failure is a partial clone THIS
    // call created — a kill on timeout (TerminateProcess on Windows) leaves it
    // behind rather than cleaning up after itself, and every retry would
    // otherwise fail TARGET_EXISTS forever.
    try { rmSync(target, { recursive: true, force: true }); } catch { /* best-effort cleanup */ }
    throw new GitCloneError("CLONE_FAILED", reason);
  }
  return target;
}
