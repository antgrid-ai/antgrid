import { readdirSync, type Dirent } from "node:fs";
import { join } from "node:path";
import { createMessage, type AbMessage } from "./protocol";
import { containedExcludes, escapeGlob } from "./file-search";
import { loadIgnoreRules, type IgnoreRules } from "./file-tree";
import { logger } from "./logger";

const log = logger.child({ component: "file-find" });

// Duplicated from agent-core.ts's `yieldToEventLoop` (same comment, same
// reasoning) rather than imported: agent-core.ts imports FileFinder, so an
// import the other way would be circular. Hand the event loop one full turn —
// `setImmediate` fires in libuv's check phase (after poll), so pending
// loopback accepts and reads are serviced before we resume; a microtask
// (`await Promise.resolve()`) would not be. See D13/guard 8: an unignored
// walk is 40k-300k stats, and a synchronous one reproduces the block that
// made the app reap a healthy host mid-open.
const yieldToEventLoop = () => new Promise<void>((r) => setImmediate(r));

/** `"none"` means no engine ran at all — a listing that was superseded, timed
 *  out or threw. Without it the error paths had to claim `"walk"`, which made
 *  the wire field say "the readdir fallback answered" on machines that have
 *  both binaries and never touched it. */
export type FindEngineKind = "ripgrep" | "git-ls-files" | "walk" | "none";

export interface FindEntry {
  path: string;
  isDir: boolean;
  /** Same meaning as `FileTreeNode.ignored`: git excludes this path, and it is
   *  in the answer only because `includeIgnored` was true. The filter box
   *  replaces the tree on screen, so a result the tree would dim has to arrive
   *  dimmable or the same path reads two different ways in two surfaces. */
  ignored?: true;
}

export interface FindOptions {
  /** All fields below are `unknown` on purpose: parseMessageFast validates the
   *  message TYPE alone (see the comment on FileFindMessage in protocol.ts),
   *  so a real inbound `file:find` never had its Zod bounds enforced. Every
   *  field here is clamped or defaulted by hand instead of trusted. */
  projectId: unknown;
  requestId: unknown;
  query: unknown;
  includeIgnored: unknown;
  kinds: unknown;
  limit: unknown;
}

const MAX_QUERY_LEN = 256; // mirrors FileFindMessage's declared (unenforced) cap
/** Same hand-clamp as the query, for the two fields that are echoed straight
 *  back into the reply: an unbounded requestId is reflected verbatim through
 *  the relay and charged against the credit window. */
const MAX_ID_LEN = 256;
const DEFAULT_LIMIT = 100;
const MAX_LIMIT = 500;
/** Engine output lines / walk entries examined before a listing gives up and
 *  marks itself truncated — independent of `limit`, which bounds the MATCHED
 *  result, not the raw scan. */
const MAX_SCANNED = 100_000;
/** D12: re-list only when `seq` has moved AND this TTL has elapsed since the
 *  last list — `bumpFileSeq` fires on every watcher flush (100-750ms), so a
 *  seq-only cache is cold on nearly every keystroke during an agent run,
 *  which is exactly when mentions are used. */
const FIND_CACHE_MIN_TTL_MS = 2_000;
/** Short on purpose: file-search.ts's TIMEOUT_MS (30s) would hold an
 *  @-mention popup open for half a minute on a hang. A full unignored listing
 *  of this repo measures ~80ms (docs/file-tree-lazy-expansion-spec.md's scout
 *  report) — 5s is generous, not tight. */
const FIND_TIMEOUT_MS = 5_000;
/** Entries examined in the `walk` fallback between yields — see D13. */
const WALK_YIELD_EVERY = 200;
/** Entries scored between yields. The match runs on every debounced keystroke
 *  and, unlike the walk, on a cache hit too, so it is the one piece of work
 *  guaranteed to be on the event loop while the user types. */
const MATCH_YIELD_EVERY = 5_000;

let cachedFindEngine: Exclude<FindEngineKind, "none"> | null = null;

/** Own cache and own three-way result, deliberately not file-search.ts's
 *  `detectEngine`: that cache is typed `"ripgrep" | "git-grep"` and
 *  `FileSearcher.search` dispatches on a bare ternary over it — widening it
 *  would make a `"walk"` verdict silently run git-grep. This throws nothing;
 *  the absence of both binaries IS the third verdict. */
async function detectFindEngine(): Promise<Exclude<FindEngineKind, "none">> {
  if (cachedFindEngine) return cachedFindEngine;
  try {
    const proc = Bun.spawn(["rg", "--version"], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    if (proc.exitCode === 0) {
      cachedFindEngine = "ripgrep";
      log.info("Find engine: ripgrep");
      return "ripgrep";
    }
  } catch {}
  try {
    const proc = Bun.spawn(["git", "--version"], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    if (proc.exitCode === 0) {
      cachedFindEngine = "git-ls-files";
      log.info("Find engine: git-ls-files");
      return "git-ls-files";
    }
  } catch {}
  cachedFindEngine = "walk";
  log.info("Find engine: walk (neither rg nor git on PATH)");
  return "walk";
}

/** `false` -> `rg --files`, `true` -> `rg --files --no-ignore`. `--hidden`
 *  accompanies BOTH: plain `rg --files` hides every dotfile (measured —
 *  `.github/`, `.gitignore`, `.claude/` all vanish without it), not only the
 *  ignored ones, so omitting it from the `false` row would make dotfile
 *  visibility depend on `includeIgnored` for no product reason. `--no-ignore`,
 *  never `--no-ignore-vcs`: the latter leaves `.ignore`/`.rgignore` in force,
 *  a different and surprising answer. No `-L`: symlinks stay unfollowed,
 *  matching the `walk` engine's refusal. */
export function buildFindRipgrepArgs(includeIgnored: boolean, excludes: readonly string[]): string[] {
  const args = ["rg", "--files", "--hidden"];
  if (includeIgnored) args.push("--no-ignore");
  // Floor (D9), every call and BOTH flag values — `--no-ignore` is precisely
  // what makes rg descend into a real `.git/` directory (5,026 extra paths in
  // the main checkout, measured), so moving this inside the `if` is the
  // regression to guard against. `!/X/` is a silent no-op on ripgrep 14 — see
  // file-search.ts's buildRipgrepArgs comment and this file's own regression
  // test. `**` anchors it for real. This glob alone does not suppress a BARE
  // `.git` entry (a managed worktree's `.git` is an 86-byte pointer FILE, not
  // a directory — `/**` matches contents, not the entry itself) — the ignore
  // prune below covers that half.
  args.push("--glob", "!/.git/**");
  for (const rel of excludes) args.push("--glob", `!/${escapeGlob(rel)}/**`);
  return args;
}

/** `false` -> `--exclude-standard` (git's normal ignore rules), `true` ->
 *  omitted (D9/D10's "show everything" — `-o` without `--exclude-standard`
 *  recurses into ignored directories too, verified). Needs no `.git` floor:
 *  `git ls-files` never emits `.git` in any form, in any mode — verified. */
export function buildFindGitArgs(includeIgnored: boolean, excludes: readonly string[]): string[] {
  // `-z` is load-bearing, not a micro-optimisation: `core.quotePath` defaults
  // to true, so without it git renders any path holding a byte above 0x7F, a
  // quote or a backslash as a C-quoted octal-escaped string — `café.txt`
  // arrives as the literal `"caf\303\251.txt"`, and the separator rewrite then
  // turns it into `"caf/303/251.txt"` plus two directories that do not exist.
  // NUL-delimited output is verbatim, and it is also the only form that
  // survives a newline inside a filename.
  const args = ["git", "ls-files", "-z", "--cached", "--others"];
  if (!includeIgnored) args.push("--exclude-standard");
  args.push("--", ".");
  for (const rel of excludes) args.push(`:(exclude,literal)${rel}`);
  return args;
}

/** Only the walk and ripgrep engines can emit a Windows separator. Git always
 *  emits `/`, and a backslash is a legal character in a filename on
 *  Linux/macOS, so rewriting git's output would corrupt a real path. */
function normalizeSeparators(line: string): string {
  return line.replace(/\\/g, "/");
}

/** The half of the `.git` floor a glob can't reach: a managed worktree's
 *  `.git` is a pointer FILE, and `rg --files --hidden` lists it even without
 *  `--no-ignore` (measured). Harmless to run against git's own output too —
 *  git never emits it, so this is always a no-op there. */
function isFloorEntry(rel: string): boolean {
  return rel === ".git" || rel.startsWith(".git/");
}

/** Decides one engine-emitted path against the SAME rules the tree applies, so
 *  `includeIgnored` means one thing across all three engines and agrees with
 *  `file:tree:children`.
 *
 *  `rg --files --no-ignore` and `git ls-files -c -o` apply no convenience list
 *  of their own, while the walk engine goes through `loadIgnoreRules` — left
 *  alone that is a ~16x disagreement (42k paths vs 2.7k on this repo, 93% of
 *  it `node_modules`) decided by which binaries the machine happens to have.
 *  It also broke A1 outright: the filter box sends `includeIgnored: true` so
 *  it agrees with the tree it filters, and the tree's show-all variant keeps
 *  `DEFAULT_IGNORES` (see `IgnoreRulesOptions` in file-tree.ts), so a
 *  `node_modules/…` row was a result the tree could never reveal.
 *
 *  The ancestor memo is what makes this cheap: 39,730 `node_modules/**` paths
 *  are refused by one cached verdict on their first segment. */
class IgnorePrune {
  private readonly dirVerdict = new Map<string, boolean>();
  constructor(private readonly rules: IgnoreRules) {}

  keeps(rel: string): boolean {
    let slash = rel.indexOf("/");
    while (slash !== -1) {
      const dir = rel.slice(0, slash);
      let verdict = this.dirVerdict.get(dir);
      if (verdict === undefined) {
        // Asked as a directory, or a `build/`-style pattern answers false for
        // every ancestor and the memo saves nothing on exactly the paths it
        // exists to refuse in bulk.
        verdict = this.rules.ignores(dir, true);
        this.dirVerdict.set(dir, verdict);
      }
      if (verdict) return false;
      slash = rel.indexOf("/", slash + 1);
    }
    return !this.rules.ignores(rel);
  }
}

export interface WalkOptions {
  maxScanned?: number;
  yieldEvery?: number;
  yieldFn?: () => Promise<void>;
  /** Polled between entries; a superseded/cancelled request stops the walk
   *  without needing a process to kill. */
  cancelled?: () => boolean;
}

export interface WalkResult {
  paths: string[];
  truncated: boolean;
  /** The walk reached its own end rather than being stopped by `cancelled`.
   *  A cancelled walk returns whatever it had, which is usually nothing, and
   *  must never be mistaken for "this project has no files". */
  complete: boolean;
}

/** `readdirSync` fallback for a machine with neither `rg` nor `git` (D13).
 *  Chunked with `yieldFn` (real `yieldToEventLoop` in production) — an
 *  unignored walk is 40k-300k stats, and running it synchronously reproduces
 *  the ~10.9s block that made the app reap a healthy host mid-open (see the
 *  comment above `FileWatcher.startWatching`). Exported so a test can assert
 *  the chunking (call count) rather than wall-clock, and force the fallback
 *  without needing a machine that actually lacks rg/git. */
export async function walkFiles(root: string, rules: IgnoreRules, opts: WalkOptions = {}): Promise<WalkResult> {
  const maxScanned = opts.maxScanned ?? MAX_SCANNED;
  const yieldEvery = opts.yieldEvery ?? WALK_YIELD_EVERY;
  const yieldFn = opts.yieldFn ?? yieldToEventLoop;
  const isCancelled = opts.cancelled ?? (() => false);
  const out: string[] = [];
  let scanned = 0;
  let truncated = false;
  let cancelled = false;

  async function visit(absDir: string, relDir: string): Promise<void> {
    if (truncated || cancelled) return;
    if (isCancelled()) {
      cancelled = true;
      return;
    }
    let entries: Dirent[];
    try {
      entries = readdirSync(absDir, { withFileTypes: true });
    } catch {
      return;
    }
    // Code-unit order, matching file-tree.ts's walk()/listDirectory: cheap,
    // deterministic, and independent of the host's ICU data.
    entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const entry of entries) {
      if (isCancelled()) {
        cancelled = true;
        return;
      }
      if (scanned >= maxScanned) {
        truncated = true;
        return;
      }
      scanned++;
      if (scanned % yieldEvery === 0) await yieldFn();
      if (entry.isSymbolicLink()) continue;
      const rel = relDir === "" ? entry.name : `${relDir}/${entry.name}`;
      if (rules.ignores(rel, entry.isDirectory())) continue;
      if (entry.isDirectory()) {
        await visit(join(absDir, entry.name), rel);
      } else if (entry.isFile()) {
        out.push(rel);
      }
    }
  }

  await visit(root, "");
  return { paths: out, truncated, complete: !cancelled };
}

/** D15: neither `rg --files` nor `git ls-files` (nor the walk fallback, which
 *  only ever pushes files) emits a directory — verified. Directories are
 *  derived from the path prefixes of the files that survived. Consequence
 *  accepted knowingly: an empty directory is invisible to `file:find`. */
export function deriveDirectories(paths: readonly string[]): Set<string> {
  const dirs = new Set<string>();
  for (const p of paths) {
    let slash = p.indexOf("/");
    while (slash !== -1) {
      dirs.add(p.slice(0, slash));
      slash = p.indexOf("/", slash + 1);
    }
  }
  return dirs;
}

function basenameOf(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx === -1 ? path : path.slice(idx + 1);
}

function depthOf(path: string): number {
  let depth = 1;
  for (let i = 0; i < path.length; i++) if (path.charCodeAt(i) === 47) depth++;
  return depth;
}

function isSubsequence(query: string, target: string): boolean {
  if (query.length === 0) return true;
  let qi = 0;
  for (let i = 0; i < target.length && qi < query.length; i++) {
    if (target[i] === query[qi]) qi++;
  }
  return qi === query.length;
}

/** A listing entry with the query-independent work already done. Built once
 *  per LISTING and memoised with it, not once per keystroke: lowercasing 48k
 *  paths and basenames measured a large share of the per-find cost, and it is
 *  identical for every query against the same listing. */
interface IndexedEntry {
  entry: FindEntry;
  pathLower: string;
  baseLower: string;
  depth: number;
}

export function indexFindEntries(entries: readonly FindEntry[]): IndexedEntry[] {
  const out: IndexedEntry[] = new Array(entries.length);
  for (let i = 0; i < entries.length; i++) {
    const entry = entries[i]!;
    out[i] = {
      entry,
      pathLower: entry.path.toLowerCase(),
      baseLower: basenameOf(entry.path).toLowerCase(),
      depth: depthOf(entry.path),
    };
  }
  return out;
}

/** Tightness tiers, tightest first. Without one the only tiebreak among
 *  basename hits was path depth, and `isSubsequence` is loose enough that a
 *  shallow junk match beat a deep exact one: `@index` ranked
 *  `LICENSES/LicenseRef-Third-Party-Trademark.txt` above `bridge/src/index.ts`,
 *  because `i-n-d-e-x` appears in order in the former at depth 2. */
const RANK_BASE_PREFIX = 0;
const RANK_BASE_SUBSTRING = 1;
const RANK_BASE_SUBSEQUENCE = 2;
const RANK_PATH_SUBSTRING = 3;
const RANK_PATH_SUBSEQUENCE = 4;

function rankOf(indexed: IndexedEntry, q: string): number {
  if (indexed.baseLower.startsWith(q)) return RANK_BASE_PREFIX;
  if (indexed.baseLower.includes(q)) return RANK_BASE_SUBSTRING;
  if (isSubsequence(q, indexed.baseLower)) return RANK_BASE_SUBSEQUENCE;
  if (indexed.pathLower.includes(q)) return RANK_PATH_SUBSTRING;
  if (isSubsequence(q, indexed.pathLower)) return RANK_PATH_SUBSEQUENCE;
  return -1;
}

interface Scored {
  indexed: IndexedEntry;
  rank: number;
}

/** Code-unit order, not `localeCompare`: the rest of this file and
 *  file-tree.ts's `walk` sort the same way, so the answer does not depend on
 *  the host's ICU data — and `localeCompare` as a tiebreak over tens of
 *  thousands of hits was measurable on its own. */
function bySortKey(a: Scored, b: Scored): number {
  if (a.rank !== b.rank) return a.rank - b.rank;
  if (a.indexed.depth !== b.indexed.depth) return a.indexed.depth - b.indexed.depth;
  const ap = a.indexed.entry.path;
  const bp = b.indexed.entry.path;
  return ap < bp ? -1 : ap > bp ? 1 : 0;
}

/** Subsequence match over the cached path list — NOT pushed into `rg --glob`,
 *  which loses fuzzy matching entirely. Ranked by match tightness, then by a
 *  shallower path, then alphabetically; bounded to `limit`. "Good enough for
 *  @-mentions" (spec's own bar), not a ranking engine.
 *
 *  Depth ahead of the alphabetical tiebreak is what keeps a matched DIRECTORY
 *  reachable past the cap: it is always shallower than the files under it, so
 *  it outranks them. That was an explicit rule of the Dart ranker this
 *  replaced and it is load-bearing for the @-mention panel. */
export function matchFindEntries(entries: readonly FindEntry[], query: string, limit: number): FindEntry[] {
  const q = query.toLowerCase();
  const scored: Scored[] = [];
  for (const indexed of indexFindEntries(entries)) {
    const rank = rankOf(indexed, q);
    if (rank >= 0) scored.push({ indexed, rank });
  }
  scored.sort(bySortKey);
  return scored.slice(0, Math.max(0, limit)).map((s) => s.indexed.entry);
}

interface CacheEntry {
  seq: number;
  listedAt: number;
  engine: FindEngineKind;
  truncated: boolean;
  paths: string[];
  /** Derived once per listing. Deriving directories from 42k path prefixes
   *  measured ~100ms and used to run on every find, including a cache hit
   *  whose path list was byte-identical to the last one's. */
  files: IndexedEntry[];
  dirs: IndexedEntry[];
}

interface FreshListing {
  paths: string[];
  truncated: boolean;
  engine: FindEngineKind;
  /** The listing ran to its own end. A superseded, timed-out or killed run
   *  returns `false` and is neither cached nor reported as an answer — the
   *  cache write used to be guarded only against a SUPERSEDE, so a timeout
   *  wrote its empty result and D12's `seq`-equality clause then served it
   *  for as long as no file changed on disk. */
  complete: boolean;
}

export interface FinderTestHooks {
  now?: () => number;
  yieldFn?: () => Promise<void>;
  /** Arms this request's timeout and returns its disarm. Injectable because a
   *  test that proves a timed-out listing is neither cached nor reported as an
   *  empty answer has to fire the timeout at a chosen point in the listing,
   *  which a wall-clock timer cannot be made to do deterministically. */
  armTimeout?: (fire: () => void) => () => void;
}

function defaultArmTimeout(fire: () => void): () => void {
  const handle = setTimeout(fire, FIND_TIMEOUT_MS);
  return () => clearTimeout(handle);
}

/** One in-flight request's mutable state. Lives in a per-request object rather
 *  than in fields on the finder so a superseded call's timeout and cleanup can
 *  never act on its replacement's process — the two CLEANUP sites were already
 *  identity-gated, the two MUTATION sites were not. */
interface ActiveFind {
  requestId: string;
  proc: ReturnType<typeof Bun.spawn> | null;
  /** Set only when WE killed the run. It is the one thing that distinguishes a
   *  killed `git ls-files` from a genuine exit 128, and without it every
   *  supersede took the walk fallback and logged a "non-repository root"
   *  warning against a repo that plainly is one. */
  killed: boolean;
  timedOut: boolean;
}

/** Bridge-side path search backing @-mentions and the tree's filter box (see
 *  docs/file-tree-lazy-expansion-spec.md). One instance per checkout, same
 *  lifetime as its FileWatcher/FileSearcher siblings — `getSeq` is that
 *  checkout's `FileWatcher.currentSeq`, which is what D12's cache keys
 *  freshness on. */
export class FileFinder {
  private projectRoot: string;
  private projectId: string;
  private sendMessage: (msg: AbMessage) => void;
  private excludes: string[];
  private getSeq: () => number;
  private now: () => number;
  private yieldFn: () => Promise<void>;
  private armTimeout: NonNullable<FinderTestHooks["armTimeout"]>;
  private cache = new Map<string, CacheEntry>();
  private active: ActiveFind | null = null;

  /** `excludeDirs` is exactly what FileSearcher's constructor takes — the
   *  Antgrid state dir, so the floor drops it the same way a content search
   *  does. `testHooks` exists only so tests can control TTL passage, the
   *  timeout and event-loop yielding deterministically instead of racing real
   *  timers. */
  constructor(
    projectRoot: string,
    projectId: string,
    sendMessage: (msg: AbMessage) => void,
    excludeDirs: readonly string[] = [],
    getSeq: () => number = () => 0,
    testHooks?: FinderTestHooks,
  ) {
    this.projectRoot = projectRoot;
    this.projectId = projectId;
    this.sendMessage = sendMessage;
    this.excludes = containedExcludes(projectRoot, excludeDirs);
    this.getSeq = getSeq;
    this.now = testHooks?.now ?? Date.now;
    this.yieldFn = testHooks?.yieldFn ?? yieldToEventLoop;
    this.armTimeout = testHooks?.armTimeout ?? defaultArmTimeout;
  }

  /** Release the engine process still holding the checkout as its cwd, and
   *  resolve only once it is gone. `git worktree remove` fails on Windows
   *  while any child holds the directory, which strands a managed session
   *  undeletable — the hazard `awaitGitRefreshes` already guards for `git
   *  status`. A find fires on a 250ms debounce from an open popup, so it is
   *  the likelier holder of the two. */
  async stop(): Promise<void> {
    const proc = this.active?.proc ?? null;
    this.abort();
    if (!proc) return;
    try {
      await proc.exited;
    } catch {}
  }

  /** Marks the outgoing request dead and kills its process. Called
   *  synchronously at the top of every `find`, so a batch of frames arriving
   *  in one tick cannot all get past the kill with nothing yet to kill. */
  private abort(): void {
    const active = this.active;
    if (!active) return;
    active.killed = true;
    active.proc?.kill();
    active.proc = null;
    this.active = null;
  }

  async find(opts: FindOptions): Promise<void> {
    this.abort();
    const requestId = clampId(opts.requestId);
    const active: ActiveFind = { requestId, proc: null, killed: false, timedOut: false };
    this.active = active;

    const projectId = clampId(opts.projectId) || this.projectId;
    const query = typeof opts.query === "string" ? opts.query.slice(0, MAX_QUERY_LEN) : "";
    // Default FALSE — the opposite of the tree's frames (D10): find hands a
    // path to an agent, and node_modules is noise there.
    const includeIgnored = opts.includeIgnored === true;
    const kinds: "files" | "dirs" | "both" =
      opts.kinds === "files" || opts.kinds === "dirs" ? opts.kinds : "both";
    const rawLimit = Number(opts.limit);
    const limit = Number.isFinite(rawLimit)
      ? Math.min(Math.max(Math.trunc(rawLimit), 1), MAX_LIMIT)
      : DEFAULT_LIMIT;

    // Scoped to THIS request. The old timer closed over nothing: it set the
    // shared cancel flag and killed whatever process the finder happened to
    // hold, so a stale request's timer could kill its successor's engine and
    // have the successor's empty result cached as complete.
    const disarm = this.armTimeout(() => {
      if (this.active !== active) return;
      active.timedOut = true;
      active.killed = true;
      active.proc?.kill();
      active.proc = null;
    });

    let listed: CacheEntry;
    try {
      listed = await this.listPaths(includeIgnored, active);
    } catch (err: unknown) {
      disarm();
      this.reply(projectId, requestId, [], true, "none", err instanceof Error ? err.message : String(err));
      return;
    }
    disarm();

    if (active.killed) {
      // Answered, never silently dropped (there is no file:find-cancel), but
      // answered honestly: `truncated` plus an `error` is what stops the app
      // rendering an aborted listing as a confident "No matching files".
      this.reply(
        projectId,
        requestId,
        [],
        true,
        "none",
        active.timedOut ? "file listing timed out" : "superseded by a newer file:find",
      );
      return;
    }

    const sources: IndexedEntry[][] = [];
    if (kinds !== "dirs") sources.push(listed.files);
    if (kinds !== "files") sources.push(listed.dirs);
    const entries = await this.match(sources, query, limit);
    this.reply(projectId, requestId, this.marked(entries, includeIgnored), listed.truncated, listed.engine);
  }

  /** The second verdict, the same one `listDirectory`'s `markAgainst` gives a
   *  tree listing. Only the matched prefix is judged — at most `limit` paths,
   *  against a listing that can be tens of thousands — and only when the
   *  caller asked to see ignored paths at all, since nothing ignored survived
   *  the engine otherwise. */
  private marked(entries: FindEntry[], includeIgnored: boolean): FindEntry[] {
    if (!includeIgnored || entries.length === 0) return entries;
    const gitRules = loadIgnoreRules(this.projectRoot, this.excludes, { gitignore: true });
    return entries.map((e) =>
      gitRules.ignores(e.path, e.isDir) ? { ...e, ignored: true as const } : e,
    );
  }

  /** Chunked for the same reason the walk is (D13): this is the one piece of
   *  per-find work a cache hit cannot skip, and it runs at the app's 250ms
   *  debounce cadence while the user types. */
  private async match(sources: readonly IndexedEntry[][], query: string, limit: number): Promise<FindEntry[]> {
    const q = query.toLowerCase();
    const scored: Scored[] = [];
    let seen = 0;
    for (const source of sources) {
      for (const indexed of source) {
        if (++seen % MATCH_YIELD_EVERY === 0) await this.yieldFn();
        const rank = rankOf(indexed, q);
        if (rank >= 0) scored.push({ indexed, rank });
      }
    }
    scored.sort(bySortKey);
    return scored.slice(0, limit).map((s) => s.indexed.entry);
  }

  private reply(
    projectId: string,
    requestId: string,
    entries: FindEntry[],
    truncated: boolean,
    engine: FindEngineKind,
    error?: string,
  ): void {
    // Still sent even for a superseded request — same discipline as
    // FileSearcher's `file:search-done`: there is no file:find-cancel frame,
    // and the app is the one that drops a reply for a requestId it no longer
    // wants (see the wire contract's comment).
    this.sendMessage(createMessage("file:find-result", {
      projectId,
      requestId,
      entries,
      truncated,
      engine,
      ...(error ? { error } : {}),
    }));
    if (this.active?.requestId === requestId) this.active = null;
  }

  private async listPaths(includeIgnored: boolean, active: ActiveFind): Promise<CacheEntry> {
    const cacheKey = includeIgnored ? "1" : "0";
    const seq = this.getSeq();
    const now = this.now();
    const cached = this.cache.get(cacheKey);
    if (cached && (cached.seq === seq || now - cached.listedAt < FIND_CACHE_MIN_TTL_MS)) {
      return cached;
    }
    const result = await this.listFresh(includeIgnored, active);
    const files = indexFindEntries(result.paths.map((p) => ({ path: p, isDir: false })));
    const dirs = indexFindEntries([...deriveDirectories(result.paths)].map((p) => ({ path: p, isDir: true })));
    const entry: CacheEntry = {
      seq,
      listedAt: now,
      engine: result.engine,
      truncated: result.truncated,
      paths: result.paths,
      files,
      dirs,
    };
    // Only a listing that ran to its own end may be cached. `complete` — not
    // "this request is still the current one" — is the guard: the timeout left
    // `active` intact, so the old guard passed and an empty, error-free
    // listing was cached with an unchanged `seq` and then served forever.
    if (result.complete && this.active === active) this.cache.set(cacheKey, entry);
    return entry;
  }

  private async listFresh(includeIgnored: boolean, active: ActiveFind): Promise<FreshListing> {
    const rules = loadIgnoreRules(this.projectRoot, this.excludes, { gitignore: !includeIgnored });
    const engine = await detectFindEngine();
    if (this.active !== active || active.killed) {
      return { paths: [], truncated: false, engine: "none", complete: false };
    }
    if (engine === "ripgrep") {
      return await this.listViaSpawn(buildFindRipgrepArgs(includeIgnored, this.excludes), "ripgrep", active, rules);
    }
    if (engine === "git-ls-files") {
      const result = await this.listViaSpawn(buildFindGitArgs(includeIgnored, this.excludes), "git-ls-files", active, rules);
      if (result.complete || active.killed) return result;
      // Non-zero exit that was NOT our own kill: `detectFindEngine` proved the
      // git BINARY exists, never that this checkout's root is a repository
      // (project-resolver.ts keeps answering for a non-repository on purpose,
      // and every project on the machine gets a searcher whether it is
      // git-backed or not). Fall through to walk for THIS listing only — the
      // process-wide engine cache stays "git-ls-files", because another
      // checkout may well be a real repo.
      log.warn(
        { exitCode: result.exitCode },
        "file:find git ls-files exited non-zero on its own; falling back to walk for this listing",
      );
    }
    return await this.listViaWalk(includeIgnored, active, rules);
  }

  private async listViaSpawn(
    args: string[],
    engine: "ripgrep" | "git-ls-files",
    active: ActiveFind,
    rules: IgnoreRules,
  ): Promise<FreshListing & { exitCode: number | null }> {
    const aborted = (): FreshListing & { exitCode: number | null } =>
      ({ paths: [], truncated: false, engine: "none", complete: false, exitCode: null });
    if (this.active !== active || active.killed) return aborted();

    const proc = Bun.spawn(args, { stdout: "pipe", stderr: "pipe", cwd: this.projectRoot });
    if (this.active !== active || active.killed) {
      proc.kill();
      return aborted();
    }
    active.proc = proc;

    // `git ls-files -z` is NUL-delimited and verbatim; ripgrep is
    // newline-delimited and, on Windows, uses `\` separators.
    const nulDelimited = engine === "git-ls-files";
    const separator = nulDelimited ? "\0" : "\n";
    const prune = new IgnorePrune(rules);
    const paths: string[] = [];
    let truncated = false;
    let scanned = 0;
    let cappedKill = false;

    const take = (raw: string): void => {
      if (!raw) return;
      const rel = nulDelimited ? raw : normalizeSeparators(raw.replace(/\r$/, "").trim());
      if (!rel || isFloorEntry(rel)) return;
      if (!prune.keeps(rel)) return;
      paths.push(rel);
    };

    try {
      const reader = proc.stdout.getReader();
      const decoder = new TextDecoder();
      let leftover = "";
      outer: while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = leftover + decoder.decode(value, { stream: true });
        const lines = text.split(separator);
        leftover = lines.pop() ?? "";
        for (const line of lines) {
          if (scanned >= MAX_SCANNED) {
            truncated = true;
            cappedKill = true;
            proc.kill();
            break outer;
          }
          scanned++;
          take(line);
        }
      }
      if (!truncated) take(leftover);
    } catch {
      // Best-effort partial results on a stream error, same discipline as
      // FileSearcher's read loop.
    }

    await proc.exited;
    if (active.proc === proc) active.proc = null;
    const exitCode = proc.exitCode;
    // A cap kill is our own, but it is a deliberate ANSWER (flagged
    // `truncated`), not an abandoned run — unlike a supersede or a timeout.
    const complete = active.killed ? false : cappedKill || exitCode === 0;
    return { paths, truncated, engine, complete, exitCode };
  }

  private async listViaWalk(
    includeIgnored: boolean,
    active: ActiveFind,
    rules: IgnoreRules,
  ): Promise<FreshListing> {
    const result = await walkFiles(this.projectRoot, rules, {
      maxScanned: MAX_SCANNED,
      yieldEvery: WALK_YIELD_EVERY,
      yieldFn: this.yieldFn,
      cancelled: () => active.killed || this.active !== active,
    });
    return {
      paths: result.paths,
      truncated: result.truncated,
      engine: result.complete ? "walk" : "none",
      complete: result.complete,
    };
  }
}

/** Matches the handler's own `typeof x === "string" ? x : ""` on its fallback
 *  replies (agent-core.ts): without it a `requestId: {}` came back as
 *  `"[object Object]"` from here and `""` from there — two answers to one
 *  frame — and an unbounded one was reflected verbatim through the relay. */
function clampId(value: unknown): string {
  return typeof value === "string" ? value.slice(0, MAX_ID_LEN) : "";
}
