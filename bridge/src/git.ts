// bridge/src/git.ts
import { existsSync } from "node:fs";
import { join } from "node:path";

export type GitFileStatusCode = "M" | "A" | "D" | "R" | "U" | "!";

export interface GitFileEntry {
  path: string;
  status: GitFileStatusCode;
  staged: boolean;
  /** Pre-rename path; set only when status is "R" (always staged: true). */
  oldPath?: string;
  /** Added/removed line counts vs HEAD — combined across staged+unstaged,
   * so a path with both carries the SAME totals on both of its entries. 0
   * for a merge conflict (nothing to diff against) and for a binary file. */
  additions: number;
  deletions: number;
}

const CONFLICT_CODES = new Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"]);

/**
 * Parses `git status --porcelain=v1 -z` output into the buckets every git
 * op in this file needs: conflicts, staged renames, and the index (X) vs
 * worktree (Y) status of everything else — the staged/unstaged split VS
 * Code's own Source Control view is built on. `-z` sidesteps path-quoting
 * and the ` -> ` arrow ambiguity the human-readable porcelain format has.
 *
 * Porcelain reports paths from the REPOSITORY root and has no `--relative`
 * of its own (unlike `git diff`), so `prefix` — `rev-parse --show-prefix`,
 * i.e. cwd's own slash-terminated path under that root, empty at the root —
 * is what re-scopes it to the project: anything not under it is another
 * project's business and is dropped, and what remains is re-keyed relative
 * to cwd so it matches the file tree and the pathspecs every op here passes
 * back to git. Filtered HERE rather than with a `-- .` pathspec on the
 * command, because a pathspec also narrows what git will PAIR as a rename
 * (the same hazard `gitDiscard` documents below).
 */
function parsePorcelain(raw: string, prefix: string): {
  conflictPaths: Set<string>;
  renames: Map<string, string>; // newPath -> oldPath, staged renames
  staged: Map<string, GitFileStatusCode>; // from X
  unstaged: Map<string, GitFileStatusCode>; // from Y
  untracked: Set<string>;
} {
  const conflictPaths = new Set<string>();
  const renames = new Map<string, string>();
  const staged = new Map<string, GitFileStatusCode>();
  const unstaged = new Map<string, GitFileStatusCode>();
  const untracked = new Set<string>();

  const inScope = (p: string) => !prefix || p.startsWith(prefix);
  const rel = (p: string) => (prefix ? p.slice(prefix.length) : p);

  const tokens = raw.split("\0").filter((t) => t.length > 0);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const x = token[0];
    const y = token[1];
    const xy = token.slice(0, 2);
    const rawPath = token.slice(3);
    // A rename's old path is a SEPARATE token, so it has to be consumed even
    // for an out-of-scope record — otherwise it parses as the next entry.
    const rawOldPath = x === "R" || x === "C" ? tokens[++i] : undefined;
    if (!inScope(rawPath)) continue;
    const path = rel(rawPath);

    if (CONFLICT_CODES.has(xy)) {
      conflictPaths.add(path);
      continue;
    }
    if (x === "?" && y === "?") {
      untracked.add(path);
      continue;
    }
    // Copies are folded into "rename" — Antgrid doesn't model them
    // separately, and copy detection isn't even git's default, so this is
    // defensive rather than a gap that's actually reachable.
    if (x === "R" || x === "C") {
      // A rename INTO the project from outside it has no old path this
      // project can name, so it is recorded as the plain addition it looks
      // like from in here — which is also what `git diff --relative` reports
      // for that same file, keeping the two halves consistent.
      if (rawOldPath !== undefined && inScope(rawOldPath)) {
        renames.set(path, rel(rawOldPath));
      } else {
        staged.set(path, "A");
      }
    } else if (x === "D") {
      staged.set(path, "D");
    } else if (x === "A") {
      staged.set(path, "A");
    } else if (x !== " ") {
      staged.set(path, "M"); // folds type-changed ("T") into modified
    }

    if (y === "D") {
      unstaged.set(path, "D");
    } else if (y !== " ") {
      unstaged.set(path, "M"); // folds type-changed ("T") into modified
    }
  }
  return { conflictPaths, renames, staged, unstaged, untracked };
}

/**
 * Line-level added/removed counts vs HEAD, keyed by the CURRENT path —
 * combined across staged+unstaged (mirrors `git diff --stat`, not the
 * staged/unstaged split above). `-M` matches the rename detection `git
 * status` already applies, and `--relative` scopes this to cwd the same way
 * `prefix` scopes the porcelain parse (see [parsePorcelain]) — `git diff`
 * has the flag, so it needs no manual filtering.
 *
 * A record git PAIRED as a rename carries an EMPTY path field and puts both
 * halves in the two NUL-terminated tokens after it:
 *
 *     <add> TAB <del> TAB NUL <oldpath> NUL <newpath> NUL
 *     <add> TAB <del> TAB <path> NUL                        (everything else)
 *
 * so the empty field — not any porcelain-derived guess about which token is
 * an old path — is what identifies one. Key on the NEW path: it is the only
 * one callers hold (the tree has no node for the vanished old path).
 * Unpaired renames arrive as an ordinary delete + add and need nothing
 * special. "-\t-" (binary) reports as 0/0 — a byte diff nobody asked for.
 */
async function getDiffStats(
  cwd: string,
): Promise<Map<string, { additions: number; deletions: number }>> {
  const stats = new Map<string, { additions: number; deletions: number }>();
  const r = await runGit(cwd, ["diff", "HEAD", "--numstat", "-M", "-z", "--relative"]);
  if (r.exitCode !== 0) return stats;

  const tokens = r.stdout.split("\0").filter((t) => t.length > 0);
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i];
    const firstTab = token.indexOf("\t");
    const secondTab = firstTab === -1 ? -1 : token.indexOf("\t", firstTab + 1);
    if (firstTab === -1 || secondTab === -1) continue;

    const addedStr = token.slice(0, firstTab);
    const deletedStr = token.slice(firstTab + 1, secondTab);
    const additions = addedStr === "-" ? 0 : parseInt(addedStr, 10);
    const deletions = deletedStr === "-" ? 0 : parseInt(deletedStr, 10);
    const path = token.slice(secondTab + 1);

    if (path === "") {
      const newPath = tokens[i + 2]; // i+1 is the old path
      i += 2;
      if (newPath !== undefined) stats.set(newPath, { additions, deletions });
      continue;
    }
    stats.set(path, { additions, deletions });
  }
  return stats;
}

/**
 * Cap on an untracked file this module will read to count its lines, matching
 * `file-tree.ts`'s own MAX_FILE_SIZE. Anything larger reports 0 (rendered as a
 * plain dot, same as a binary file) rather than being loaded.
 *
 * Load-bearing, not defensive: `getGitStatus` runs on a 10-second interval for
 * the life of every warm project (`agent-core.ts`), and these reads are fanned
 * out concurrently — so one uncapped multi-hundred-MB untracked file (a build
 * log, a dump, anything not gitignored) is a full read plus a full scan of it
 * every 10 seconds, forever, with every such file resident at once.
 */
const MAX_UNTRACKED_STAT_BYTES = 1_048_576;

/**
 * Line count for a brand-new untracked file — the "added" half of its stat,
 * since there's no HEAD content to diff against. A trailing newline isn't
 * its own line (matches `git diff --numstat`'s count for a new file); a
 * NUL in the first 8KB is treated as binary, same as numstat's "-" column,
 * and so is anything past [MAX_UNTRACKED_STAT_BYTES].
 */
async function countAddedLines(cwd: string, relPath: string): Promise<number> {
  try {
    const file = Bun.file(join(cwd, relPath));
    // Checked BEFORE the read, which is the whole point — `.size` is a stat,
    // and reaching for `.bytes().length` instead would already have paid the
    // cost this guard exists to avoid.
    if (file.size > MAX_UNTRACKED_STAT_BYTES) return 0;
    const bytes = await file.bytes();
    if (bytes.length === 0) return 0;
    if (bytes.subarray(0, 8000).includes(0)) return 0;
    let lines = 0;
    // Indexed, not `for..of`: the iterator protocol allocates per byte.
    for (let i = 0; i < bytes.length; i++) if (bytes[i] === 10) lines++;
    return bytes[bytes.length - 1] === 10 ? lines : lines + 1;
  } catch {
    return 0;
  }
}

export interface GitOpResult {
  success: boolean;
  error?: string;
}

export interface GitCommitResult extends GitOpResult {
  sha?: string;
}

async function runGit(
  cwd: string,
  args: string[],
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  // `core.quotepath=false` keeps non-ASCII paths verbatim (UTF-8) instead of
  // git's default C-quoted/octal-escaped form (e.g. "caf\303\251.txt"). The
  // quoted form is a *literal* string that no longer matches the real file, so
  // status paths would round-trip into `add`/`restore`/`clean` pathspecs that
  // match nothing. Harmless for the pathspec-input verbs; load-bearing here.
  const proc = Bun.spawn(["git", "-c", "core.quotepath=false", ...args], {
    cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ]);
  const exitCode = await proc.exited;
  return { exitCode, stdout, stderr };
}

/**
 * One `git status --porcelain=v1 -z`, already re-scoped to `cwd` (see
 * [parsePorcelain] for why the scoping is done in the parse rather than with
 * a pathspec). The prefix probe rides alongside it rather than before it —
 * neither needs the other's answer.
 *
 * Null when git failed outright (not a repository, most often), which every
 * caller must keep distinct from a clean tree.
 */
async function readPorcelain(
  cwd: string,
): Promise<ReturnType<typeof parsePorcelain> | null> {
  const [status, prefix] = await Promise.all([
    runGit(cwd, ["status", "--porcelain=v1", "-z"]),
    runGit(cwd, ["rev-parse", "--show-prefix"]),
  ]);
  if (status.exitCode !== 0) return null;
  // Trailing newline only — never `.trim()`, which would also eat a directory
  // name's own leading/trailing spaces and break every startsWith below.
  const rel = prefix.exitCode === 0 ? prefix.stdout.replace(/\r?\n$/, "") : "";
  return parsePorcelain(status.stdout, rel);
}

/**
 * Working-tree + index status vs HEAD, in VS Code's letter vocabulary and
 * its staged/unstaged split: conflicts ("!"), staged renames ("R", with
 * `oldPath`), staged M/A/D, unstaged M/D, and untracked files ("U"). A path
 * with both a staged and a further unstaged change (e.g. staged-modified
 * then edited again) legitimately appears TWICE — once per side — exactly
 * as VS Code's own Source Control view shows it once under Staged Changes
 * and once under Changes.
 *
 * The letters all come from one `git status --porcelain=v1 -z` call — no
 * separate `git diff`/`ls-files` invocations needed, since the index (X) vs
 * worktree (Y) columns already carry the full picture. Paths are relative to
 * `cwd`, and a project rooted BELOW its repository root sees only its own
 * subtree (see [readPorcelain]) — the file tree, and every pathspec the ops
 * below hand back to git, are all cwd-relative too.
 *
 * Rename detection here inherits `git status`'s default scope: it reliably
 * fires for `git mv` and for a manually staged rename (both sides in the
 * index), the same scope VS Code's own INDEX_RENAMED covers. A working-tree
 * -only move with neither side staged has nothing to diff against and stays
 * classified as D (old path) + U (new path) — a documented limitation, not a
 * bug to chase.
 *
 * Emission order matters to callers that fold this into a single
 * path→status map (last write wins): conflicts, renames, staged, unstaged,
 * untracked — unstaged is emitted after staged so "worktree status wins"
 * falls out for free.
 */
export async function getGitStatus(cwd: string): Promise<GitFileEntry[]> {
  const porcelain = await readPorcelain(cwd);
  if (porcelain === null) return [];

  const { conflictPaths, renames, staged, unstaged, untracked } = porcelain;
  // Independent of each other — run concurrently rather than serially, and
  // fan the per-file untracked reads out too. Awaiting them one at a time
  // was the actual source of the "git changes don't show up right away"
  // startup lag: `refreshGitStatus` gates the app's real (non-empty)
  // git:status resend, so N untracked files meant N sequential fs reads on
  // the critical path before the app ever saw them.
  const untrackedList = [...untracked];
  const [diffStats, untrackedAdditions] = await Promise.all([
    getDiffStats(cwd),
    Promise.all(untrackedList.map((path) => countAddedLines(cwd, path))),
  ]);
  const statsFor = (path: string) =>
    diffStats.get(path) ?? { additions: 0, deletions: 0 };

  const entries: GitFileEntry[] = [];
  for (const path of conflictPaths) {
    entries.push({ path, status: "!", staged: false, additions: 0, deletions: 0 });
  }
  for (const [path, oldPath] of renames) {
    entries.push({ path, status: "R", staged: true, oldPath, ...statsFor(path) });
  }
  for (const [path, status] of staged) {
    entries.push({ path, status, staged: true, ...statsFor(path) });
  }
  for (const [path, status] of unstaged) {
    entries.push({ path, status, staged: false, ...statsFor(path) });
  }
  untrackedList.forEach((path, i) => {
    entries.push({
      path,
      status: "U",
      staged: false,
      additions: untrackedAdditions[i],
      deletions: 0,
    });
  });
  return entries;
}

/** Stage `files` (`git add`) — leaves committing to a separate step. */
export async function gitStage(cwd: string, files: string[]): Promise<GitOpResult> {
  if (files.length === 0) return { success: true };
  const r = await runGit(cwd, ["add", "--", ...files]);
  if (r.exitCode !== 0) return { success: false, error: r.stderr.trim() || "git add failed" };
  return { success: true };
}

/**
 * Unstage `files` (`git reset`) — drops them from the index, working tree
 * untouched. A staged rename's OLD path already has no index entry (staging
 * a rename removes it), so resetting only the new path would leave the old
 * path looking like a fresh staged deletion; pull the old path in too.
 */
export async function gitUnstage(cwd: string, files: string[]): Promise<GitOpResult> {
  if (files.length === 0) return { success: true };
  const renames = (await readPorcelain(cwd))?.renames ?? new Map<string, string>();
  const targets = new Set(files);
  for (const f of files) {
    const oldPath = renames.get(f);
    if (oldPath) targets.add(oldPath);
  }
  const r = await runGit(cwd, ["reset", "--", ...targets]);
  if (r.exitCode !== 0) return { success: false, error: r.stderr.trim() || "git reset failed" };
  return { success: true };
}

/**
 * Commit whatever is currently staged. Unlike the old file-scoped commit,
 * this deliberately includes anything staged out-of-band (external CLI, a
 * prior agent) — that's correct once staging is a real, visible step the
 * user drives via Stage/Unstage, matching VS Code: Commit commits the index
 * as-is, full stop.
 */
export async function gitCommit(
  cwd: string,
  message: string,
): Promise<GitCommitResult> {
  if (!message.trim()) return { success: false, error: "Commit message is empty" };

  const commit = await runGit(cwd, ["commit", "-m", message]);
  if (commit.exitCode !== 0) {
    return { success: false, error: commit.stderr.trim() || "git commit failed" };
  }

  // `git commit` prints "[<ref> <shorthash>] <subject>" on stdout (with an
  // optional "(root-commit)"; <ref> may itself contain a space as in
  // "detached HEAD"). Match the last hex token before the "]" rather than
  // paying a third `rev-parse` fork; sha is best-effort (left undefined if the
  // summary format ever changes).
  const sha = commit.stdout.match(/^\[.+ ([0-9a-f]{7,40})\]/m)?.[1];
  return { success: true, sha };
}

/**
 * Discard working-tree changes. Tracked files are restored to HEAD
 * (`git restore`, falling back to `git checkout --` on old git); untracked
 * files are deleted (`git clean -f`, files only — no `-d`). Both are
 * unrecoverable; callers gate on a confirm dialog.
 *
 * Tracked-vs-untracked is classified from LIVE git state here, not a cached
 * status snapshot: a file can flip tracked/untracked between the last status
 * poll and this call, and misrouting an untracked file to `restore` (errors)
 * or a tracked file to `clean` (silent no-op) would misreport the result.
 *
 * A rename is a special case: the caller only ever has the NEW path to name
 * (there's no tree node for the vanished old path), so undoing one means
 * unstaging both sides, restoring the old path's content, and removing the
 * new path — a plain `restore` on the new path alone would leave the old
 * path deleted. Conflicted (status "!") files are deliberately not handled
 * here — resolving a conflict isn't a safe "restore to HEAD", callers must
 * not offer Discard on one.
 *
 * `includeStaged` widens this from "drop the worktree edits" into a true
 * revert to HEAD. Without it a path's STAGED content survives — `restore`
 * restores the worktree from the index — so discarding a fully staged file
 * reads as a no-op to whoever asked for it. It stays opt-in because it is the
 * more destructive of the two readings, and an app that promised its user the
 * narrower one must keep getting it.
 */
export async function gitDiscard(
  cwd: string,
  files: string[],
  opts: { includeStaged?: boolean } = {},
): Promise<GitOpResult> {
  if (files.length === 0) return { success: true };

  // Whole-status, never a pathspec limited to just the new path: that stops
  // git from pairing the rename (it has nothing to compare against) and the
  // record collapses to a plain "A" — confirmed empirically, not a
  // hypothetical. [readPorcelain] narrows to this project AFTER git has
  // paired, for that reason.
  const porcelain = await readPorcelain(cwd);
  // `includeStaged` is derived ENTIRELY from this read, so an unreadable status
  // (a concurrent `index.lock` is enough) would leave `stagedPaths` empty, skip
  // the reset, and let `restore` copy the index straight back over the worktree
  // — reporting success for a discard that reverted nothing the user was
  // promised. The narrower reading fails loudly rather than being substituted
  // silently for the one they asked for.
  if (opts.includeStaged && porcelain === null) {
    return { success: false, error: "Could not read git status" };
  }
  const renames = porcelain?.renames ?? new Map<string, string>();
  const renamedNewPaths = files.filter((f) => renames.has(f));

  if (renamedNewPaths.length) {
    const renamedOldPaths = renamedNewPaths.map((f) => renames.get(f)!);
    // `git reset` resets each path's index entry to HEAD: the old path (which
    // exists at HEAD) comes back staged, the new path (which doesn't) drops
    // out of the index entirely — leaving it untracked for `clean` below.
    let r = await runGit(cwd, ["reset", "--", ...renamedNewPaths, ...renamedOldPaths]);
    if (r.exitCode !== 0) {
      return { success: false, error: r.stderr.trim() || "Discard failed" };
    }
    r = await runGit(cwd, ["checkout", "--", ...renamedOldPaths]);
    if (r.exitCode !== 0) {
      return { success: false, error: r.stderr.trim() || "Discard failed" };
    }
    r = await runGit(cwd, ["clean", "-f", "--", ...renamedNewPaths]);
    if (r.exitCode !== 0) {
      return { success: false, error: r.stderr.trim() || "Discard failed" };
    }
  }

  const remaining = files.filter((f) => !renames.has(f));

  // Drop the index entry FIRST: `restore` below copies the index back over the
  // worktree, so a staged path would otherwise come out unchanged. Resetting
  // here (rather than after) also lets the index sweep below see a staged-new
  // file as the untracked file it has just become, so `clean` deletes it —
  // which is what reverting an added-to-index file to HEAD means.
  if (opts.includeStaged) {
    const stagedPaths = remaining.filter((f) => porcelain?.staged.has(f));
    if (stagedPaths.length) {
      const r = await runGit(cwd, ["reset", "--", ...stagedPaths]);
      if (r.exitCode !== 0) {
        return { success: false, error: r.stderr.trim() || "Discard failed" };
      }
    }
  }

  // INDEX MEMBERSHIP decides how a path is undone, not `ls-files --others`,
  // and the reset above is why. A path can leave the index and appear in
  // NEITHER list: a staged-added file since deleted from the worktree is gone
  // from both, and a force-added ignored one is invisible to
  // `--exclude-standard`. Either falls through to `restore`, whose unmatched
  // pathspec aborts the WHOLE batch — every other file named in the same
  // Revert All silently left dirty, index entries already dropped. `-z` for
  // the same path-quoting reason [readPorcelain] uses it.
  const cached = await runGit(cwd, ["ls-files", "--cached", "-z", "--", ...remaining]);
  // Never guessed at: with the classification inverted, an unreadable index
  // would route every path to `clean` instead of `restore`.
  if (cached.exitCode !== 0) {
    return { success: false, error: cached.stderr.trim() || "Discard failed" };
  }
  const indexed = new Set(cached.stdout.split("\0").filter(Boolean));
  const tracked = remaining.filter((f) => indexed.has(f));
  // Reverting a path HEAD doesn't have means removing it — so a path that left
  // the index is worth cleaning only while it still exists on disk, and one
  // that exists nowhere is already at HEAD (dropped from both lists rather
  // than handed to a command that would reject the pathspec).
  const untracked = remaining.filter(
    (f) => !indexed.has(f) && existsSync(join(cwd, f)),
  );

  if (tracked.length) {
    let r = await runGit(cwd, ["restore", "--", ...tracked]);
    if (r.exitCode !== 0) {
      r = await runGit(cwd, ["checkout", "--", ...tracked]);
      if (r.exitCode !== 0) {
        return { success: false, error: r.stderr.trim() || "Discard failed" };
      }
    }
  }

  if (untracked.length) {
    // `-x`: every path here is explicitly named and no longer in the index, so
    // the only way one of them is ignored is a force-add being reverted. Plain
    // `clean` skips exactly that file and still reports success — the silent
    // no-op `includeStaged` exists to end.
    const r = await runGit(cwd, ["clean", "-f", "-x", "--", ...untracked]);
    if (r.exitCode !== 0) {
      return { success: false, error: r.stderr.trim() || "Discard failed" };
    }
  }

  return { success: true };
}
