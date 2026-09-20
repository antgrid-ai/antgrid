// bridge/src/git-spawn.ts
// Every git the bridge runs is spawned here.
//
// Five modules used to hand-roll this spawn, and they had drifted along three
// separate axes — `core.quotepath` set in three of five, `LC_ALL=C` in two,
// `GIT_OPTIONAL_LOCKS=0` in three. Nothing tests the environment of a spawn,
// so each new helper re-decided the question from scratch and no suite ever
// noticed the answer differed. What is settled here is settled for all of
// them:
//
// `core.quotepath=false` keeps non-ASCII paths verbatim (UTF-8) instead of
// git's default C-quoted, octal-escaped form. The quoted form is a *literal*
// string that no longer matches the real file, so a path read out of one git
// command and handed back to the next as a pathspec matches nothing.
//
// `GIT_OPTIONAL_LOCKS=0` suppresses only the OPPORTUNISTIC lock — the index
// refresh that a read like `status` or `diff` writes back as a courtesy. The
// bridge polls git on a per-checkout cadence ladder in the same working tree
// the user's coding agent is committing from, so that courtesy write is a race
// for `index.lock` a background read has no business entering. Every verb that
// genuinely needs the lock still takes it; this removes only the taking git
// would have done unasked.
//
// `GIT_TERMINAL_PROMPT=0` turns a credential prompt into a failure. Nothing
// here has a terminal on which to answer one, so a prompt could only ever
// hang. Configured credential helpers are unaffected.
//
// Locale is deliberately NOT settled here: see [GitSpawnOptions.englishProse].

export interface GitRun {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface GitSpawnOptions {
  /**
   * Pin git's own messages to English (`LC_ALL=C`).
   *
   * Opt-in because it is right in exactly one direction: a caller that MATCHES
   * on git's prose — `WIP on`, `would be overwritten by`, `git clean -n`'s
   * listing — needs the text to be a fact rather than a guess about the
   * machine's locale. A caller that forwards git's stderr to the user needs
   * the opposite, and would be handing them English whatever they speak.
   */
  englishProse?: boolean;

  /**
   * Kill the command after this long, reporting exit 124.
   *
   * For the verbs that reach the network, which can otherwise sit on a
   * black-holed host for as long as the transport allows. Local verbs want no
   * deadline: a slow disk is not a failure.
   */
  timeoutMs?: number;
}

function gitEnv(opts: GitSpawnOptions): Record<string, string | undefined> {
  const env: Record<string, string | undefined> = {
    ...process.env,
    GIT_OPTIONAL_LOCKS: "0",
    GIT_TERMINAL_PROMPT: "0",
  };
  if (opts.englishProse) env.LC_ALL = "C";
  return env;
}

/**
 * The subprocess itself, for a caller that must read the streams on its own
 * terms — a bounded read, or one that abandons the pipes on a deadline.
 * Everything else wants [runGit].
 */
export function spawnGit(cwd: string, args: string[], opts: GitSpawnOptions = {}) {
  return Bun.spawn(["git", "-c", "core.quotepath=false", ...args], {
    cwd,
    env: gitEnv(opts),
    stdout: "pipe",
    stderr: "pipe",
  });
}

/** One git command, read to completion. */
export async function runGit(
  cwd: string,
  args: string[],
  opts: GitSpawnOptions = {},
): Promise<GitRun> {
  const proc = spawnGit(cwd, args, opts);
  const settled = (async () => {
    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    return { exitCode: await proc.exited, stdout, stderr };
  })();
  if (!opts.timeoutMs) return settled;

  // The deadline races the READS, not just the process. Killing git alone does
  // not end them: `ls-remote` over ssh hands its stdout/stderr pipes to a child
  // `ssh`, which keeps the write ends open — and against a black-holed host
  // that child outlives the timer by ssh's own connect timeout, so awaiting the
  // pipes here would blow the deadline this exists to hold.
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<null>((resolve) => {
    timer = setTimeout(() => {
      proc.kill();
      resolve(null);
    }, opts.timeoutMs);
  });
  // The loser keeps running with nobody awaiting it; it never rejects, but the
  // handler is what keeps that from being reported as an unhandled rejection.
  settled.catch(() => undefined);
  const won = await Promise.race([settled, deadline]);
  clearTimeout(timer);
  return won ?? { exitCode: 124, stdout: "", stderr: `git ${args[0]} exceeded ${opts.timeoutMs}ms` };
}
