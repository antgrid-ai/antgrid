import { existsSync, statSync } from "node:fs";
import { join } from "node:path";
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
}): Promise<string> {
  const { url, parentDir } = args;
  if (!isCloneableUrl(url)) {
    throw new GitCloneError("BAD_URL", "Only https, ssh and git@ repository URLs can be cloned.");
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
  const r = await runGitRemote(parentDir, ["clone", "--", url, dirName], CLONE_TIMEOUT_MS);
  if (r.exitCode !== 0) {
    const reason = r.stderr.trim().split("\n").pop() || `git clone exited ${r.exitCode}`;
    throw new GitCloneError("CLONE_FAILED", reason);
  }
  return target;
}
