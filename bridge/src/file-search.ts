import { isAbsolute, relative, resolve, sep } from "node:path";
import { createMessage, type AbMessage } from "./protocol";
import { logger } from "./logger";
const log = logger.child({ component: "file-search" });

export type SearchEngine = "ripgrep" | "git-grep";

let cachedEngine: SearchEngine | null = null;

async function detectEngine(): Promise<SearchEngine> {
  if (cachedEngine) return cachedEngine;
  try {
    const proc = Bun.spawn(["rg", "--version"], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    if (proc.exitCode === 0) {
      cachedEngine = "ripgrep";
      log.info("Search engine: ripgrep");
      return "ripgrep";
    }
  } catch {}
  try {
    const proc = Bun.spawn(["git", "--version"], { stdout: "pipe", stderr: "pipe" });
    await proc.exited;
    if (proc.exitCode === 0) {
      cachedEngine = "git-grep";
      log.info("Search engine: git-grep");
      return "git-grep";
    }
  } catch {}
  throw new Error("No search engine available (install ripgrep or git)");
}

interface SearchOptions {
  projectId: string;
  query: string;
  caseSensitive: boolean;
  regex: boolean;
  wholeWord: boolean;
  requestId: string;
}

export interface SearchMatchData {
  path: string;
  line: number;
  column: number;
  lineContent: string;
  contextBefore: string[];
  contextAfter: string[];
}

const MAX_RESULTS = 10_000;
const BATCH_SIZE = 20;
const BATCH_INTERVAL_MS = 50;
const TIMEOUT_MS = 30_000;
const MAX_LINE_LENGTH = 500;
// `s`: a lone `\r` inside a line (an old-Mac line ending in one file of a CRLF
// checkout) must not cost the whole line its match.
const GIT_GREP_MATCH_RE = /^(.+?):(\d+):(\d+):(.*)$/s;
const GIT_GREP_CONTEXT_RE = /^(.+?)-(\d+)-(.*)$/s;

/**
 * Root-relative POSIX paths for the excludes that actually sit inside `root`.
 * An exclude elsewhere is dropped rather than passed through: a searcher rooted
 * at a managed worktree lives UNDER the Antgrid state dir, and anchoring an
 * exclude at an ancestor would blank its own results.
 */
export function containedExcludes(root: string, excludeDirs: readonly string[]): string[] {
  const rels: string[] = [];
  for (const dir of excludeDirs) {
    const rel = relative(root, dir);
    if (!rel || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) continue;
    rels.push(rel.split(sep).join("/"));
  }
  return rels;
}

/** globset treats these as syntax, so a state dir spelled with one would
 *  otherwise exclude a pattern instead of the directory the user named. */
export function escapeGlob(path: string): string {
  return path.replace(/[\\*?\[\]{}]/g, (ch) => `\\${ch}`);
}

export function buildRipgrepArgs(opts: SearchOptions, excludes: readonly string[]): string[] {
  const args = ["rg", "--json", "-n", "--column", "-C", "2"];
  // A leading `/` anchors the glob at ripgrep's WORKING directory, which the
  // spawn below pins to projectPath — without the anchor `!state/` would also
  // hide a `sub/state/` the project genuinely owns. The anchor alone is not
  // enough, though: on ripgrep 14, `!/X/` (and `!/X`) match NOTHING — silently
  // inert, measured four independent ways against this exact fixture (see
  // file-find.ts's buildFindRipgrepArgs and its regression test).
  // `!/X/**` is the form that actually excludes. Do not
  // "simplify" this back to a bare trailing slash — it compiles, it reads as
  // obviously correct, and it excludes nothing.
  for (const rel of excludes) args.push("--glob", `!/${escapeGlob(rel)}/**`);
  if (!opts.caseSensitive) args.push("-i");
  if (opts.wholeWord) args.push("-w");
  if (!opts.regex) args.push("-F");
  // `.`, never the project's absolute path: the anchor above resolves against
  // the cwd the OS hands back canonicalized, so a root reached through a
  // symlink (every macOS temp dir, /var -> /private/var) never sits under it
  // and the exclude goes inert.
  args.push("--", opts.query, ".");
  return args;
}

function buildGitGrepArgs(opts: SearchOptions, projectPath: string, excludes: readonly string[]): string[] {
  // --no-index rather than --untracked: plain `git grep` refuses a folder that
  // is not a repository, and a project need not be one. --exclude-standard keeps
  // .gitignore honoured, as it is inside a repo.
  const args = ["git", "-C", projectPath, "grep", "-n", "--column", "-C", "2", "--no-index", "--exclude-standard"];
  if (!opts.caseSensitive) args.push("-i");
  if (opts.wholeWord) args.push("-w");
  if (opts.regex) args.push("-P");
  else args.push("-F");
  args.push("-e", opts.query, "--", ".");
  for (const rel of excludes) args.push(`:(exclude,literal)${rel}`);
  return args;
}

/** A line as an engine printed it, minus its terminator. Git for Windows
 *  checks out CRLF by default (`core.autocrlf=true`), so every line git grep
 *  prints from such a file — and every `lines.text` ripgrep reports — carries
 *  the file's `\r`. Left on, it made both git-grep regexes fail (`.` does not
 *  match `\r`) and every match on a CRLF checkout was silently dropped. */
function stripEol(text: string): string {
  if (text.endsWith("\n")) text = text.slice(0, -1);
  if (text.endsWith("\r")) text = text.slice(0, -1);
  return text;
}

/** Turns one engine's stdout into matches with their context. Fed decoded
 *  text in arbitrary chunks; `end()` flushes the final line and match. */
export class SearchOutputParser {
  private leftover = "";
  private before: string[] = [];
  private matchLine: SearchMatchData | null = null;
  private afterCount = 0;

  constructor(
    private readonly engine: SearchEngine,
    private readonly projectRoot: string,
    private readonly onMatch: (match: SearchMatchData) => void,
  ) {}

  push(text: string): void {
    const lines = (this.leftover + text).split("\n");
    this.leftover = lines.pop() ?? "";
    for (const line of lines) this.processLine(line);
  }

  end(): void {
    const last = this.leftover;
    this.leftover = "";
    this.processLine(last);
    this.flushMatch();
  }

  private processLine(raw: string): void {
    const line = stripEol(raw);
    if (!line.trim()) return;
    if (this.engine === "ripgrep") this.processRipgrepLine(line);
    else this.processGitGrepLine(line);
  }

  private flushMatch(): void {
    if (this.matchLine) {
      this.onMatch(this.matchLine);
      this.matchLine = null;
    }
  }

  private resetContext(): void {
    this.before = [];
    this.afterCount = 0;
  }

  private pushContext(content: string): void {
    if (this.matchLine && this.afterCount < 2) {
      this.matchLine.contextAfter.push(content);
      this.afterCount++;
    } else {
      this.before.push(content);
      if (this.before.length > 2) this.before.shift();
    }
  }

  private startMatch(path: string, line: number, column: number, content: string): void {
    this.flushMatch();
    this.matchLine = {
      path,
      line,
      column,
      lineContent: content.length > MAX_LINE_LENGTH ? content.slice(0, MAX_LINE_LENGTH) : content,
      contextBefore: [...this.before],
      contextAfter: [],
    };
    this.resetContext();
  }

  private processRipgrepLine(line: string): void {
    let obj: any;
    try {
      obj = JSON.parse(line);
    } catch {
      return;
    }
    if (obj.type === "context") {
      this.pushContext(stripEol(obj.data?.lines?.text ?? ""));
    } else if (obj.type === "match") {
      const data = obj.data;
      // ripgrep echoes the `.` it was handed, so this arrives as `./x`;
      // the app opens results by bare project-relative path.
      const rawPath: string = data.path?.text ?? "";
      const relPath = relative(this.projectRoot, resolve(this.projectRoot, rawPath)).split(sep).join("/");
      const col = data.submatches?.[0]?.start ?? 0;
      this.startMatch(relPath, data.line_number ?? 0, col + 1, stripEol(data.lines?.text ?? ""));
    } else if (obj.type === "begin" || obj.type === "end") {
      this.flushMatch();
      this.resetContext();
    }
  }

  private processGitGrepLine(line: string): void {
    if (line === "--") {
      this.flushMatch();
      this.resetContext();
      return;
    }
    const m = GIT_GREP_MATCH_RE.exec(line);
    if (m) {
      this.startMatch(m[1]!, parseInt(m[2]!, 10), parseInt(m[3]!, 10), m[4]!);
      return;
    }
    const c = GIT_GREP_CONTEXT_RE.exec(line);
    if (c) this.pushContext(c[3]!);
  }
}

export class FileSearcher {
  private projectRoot: string;
  private projectId: string;
  private sendMessage: (msg: AbMessage) => void;
  private excludes: string[];
  private activeProcess: ReturnType<typeof Bun.spawn> | null = null;
  private activeRequestId: string | null = null;
  private timeoutMs: number;

  /**
   * `excludeDirs` are absolute directories that are not project content even
   * when they sit inside the root — the Antgrid state dir, which holds every
   * managed worktree. Without it a main-scoped search reports hits from the
   * isolated checkouts it is supposed to be isolated from (file-tree.ts keeps
   * the same directory out of the tree). `testHooks.timeoutMs` exists so a
   * test can make the timeout fire on a fixture git answers in milliseconds.
   */
  constructor(
    projectRoot: string,
    projectId: string,
    sendMessage: (msg: AbMessage) => void,
    excludeDirs: readonly string[] = [],
    testHooks?: { timeoutMs?: number },
  ) {
    this.projectRoot = projectRoot;
    this.projectId = projectId;
    this.sendMessage = sendMessage;
    this.excludes = containedExcludes(projectRoot, excludeDirs);
    this.timeoutMs = testHooks?.timeoutMs ?? TIMEOUT_MS;
  }

  /** Also honoured before the process exists: clearing the request id is what
   *  stops a search still probing for its engine from spawning at all. */
  cancel(requestId: string): void {
    if (this.activeRequestId !== requestId) return;
    this.activeProcess?.kill();
    this.activeProcess = null;
    this.activeRequestId = null;
  }

  /** Kill whatever search is running, whoever asked for it, and resolve only
   *  once the process is actually gone. The spawn holds the checkout as its
   *  cwd, so a caller about to run `git worktree remove` has to WAIT — see
   *  stopCheckoutServices in agent-core.ts. */
  async stop(): Promise<void> {
    const proc = this.activeProcess;
    this.activeProcess = null;
    this.activeRequestId = null;
    if (!proc) return;
    proc.kill();
    try {
      await proc.exited;
    } catch {}
  }

  async search(opts: SearchOptions): Promise<void> {
    if (this.activeProcess) {
      this.activeProcess.kill();
      this.activeProcess = null;
    }
    this.activeRequestId = opts.requestId;

    const startTime = Date.now();
    let engine: SearchEngine;
    try {
      engine = await detectEngine();
    } catch (err: any) {
      this.sendMessage(createMessage("file:search-done", {
        projectId: this.projectId,
        requestId: opts.requestId,
        totalMatches: 0,
        totalFiles: 0,
        duration: Date.now() - startTime,
        engine: "ripgrep" as const,
        error: err.message,
      }));
      return;
    }
    // A newer search (or a stop) that landed during the engine probe had no
    // process of ours to kill; spawning now would leave this one running
    // untracked beside its successor.
    if (this.activeRequestId !== opts.requestId) {
      this.sendMessage(createMessage("file:search-done", {
        projectId: this.projectId,
        requestId: opts.requestId,
        totalMatches: 0,
        totalFiles: 0,
        duration: Date.now() - startTime,
        engine,
        error: "Search cancelled",
      }));
      return;
    }

    const args = engine === "ripgrep"
      ? buildRipgrepArgs(opts, this.excludes)
      : buildGitGrepArgs(opts, this.projectRoot, this.excludes);

    const proc = Bun.spawn(args, {
      stdout: "pipe",
      stderr: "pipe",
      cwd: this.projectRoot,
    });
    this.activeProcess = proc;
    // Drained concurrently: an unread pipe that fills would stall the engine.
    const stderrText = new Response(proc.stderr).text().catch(() => "");

    const batch: SearchMatchData[] = [];
    const filesWithMatches = new Set<string>();
    let totalMatches = 0;
    let truncated = false;
    let batchTimer: ReturnType<typeof setTimeout> | null = null;
    // Our own kills, told apart by reason: `proc.signalCode` says only how the
    // engine died, and a timed-out one with nothing found yet went out as a
    // confident "No results".
    let timedOut = false;

    const timeout = setTimeout(() => {
      timedOut = true;
      proc.kill();
    }, this.timeoutMs);

    const flushBatch = () => {
      if (batch.length === 0) return;
      this.sendMessage(createMessage("file:search-result", {
        projectId: this.projectId,
        requestId: opts.requestId,
        matches: [...batch],
      }));
      batch.length = 0;
    };

    const addMatch = (match: SearchMatchData) => {
      if (truncated) return;
      totalMatches++;
      filesWithMatches.add(match.path);
      batch.push(match);
      if (batch.length >= BATCH_SIZE) {
        flushBatch();
      } else if (!batchTimer) {
        batchTimer = setTimeout(() => {
          batchTimer = null;
          flushBatch();
        }, BATCH_INTERVAL_MS);
      }
      if (totalMatches >= MAX_RESULTS) {
        truncated = true;
        proc.kill();
      }
    };

    const parser = new SearchOutputParser(engine, this.projectRoot, addMatch);
    const reader = proc.stdout.getReader();
    const decoder = new TextDecoder();
    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        parser.push(decoder.decode(value, { stream: true }));
      }
      parser.push(decoder.decode());
      parser.end();
    } catch {}

    clearTimeout(timeout);
    if (batchTimer) {
      clearTimeout(batchTimer);
      batchTimer = null;
    }
    flushBatch();

    await proc.exited;

    // Read before the identity reset below: a `cancel`, a `stop` or a newer
    // `search` has already moved `activeProcess` off this process.
    const superseded = this.activeProcess !== proc;
    let error: string | undefined;
    if (truncated) {
      error = `Results truncated at ${MAX_RESULTS} matches`;
    } else if (timedOut) {
      error = totalMatches === 0
        ? `Search timed out after ${Math.round(this.timeoutMs / 1000)}s`
        : `Search timed out after ${Math.round(this.timeoutMs / 1000)}s; results are incomplete`;
      log.warn({ totalMatches }, "search timed out");
    } else if (superseded) {
      // Still answered (callers drop a requestId they no longer want — there
      // is no cancel ack), but never as a zero-result answer.
      error = "Search cancelled";
    } else {
      // Exit 1 is "no matches" for both engines; anything above it is a
      // failure (bad regex, not a repository) that would otherwise read as
      // zero results.
      const code = proc.exitCode;
      if (totalMatches === 0 && !proc.signalCode && code !== null && code > 1) {
        const detail = (await stderrText).trim().split("\n")[0]?.slice(0, 300);
        error = detail || `Search failed (exit ${code})`;
        log.warn({ code, detail }, "search engine failed");
      }
    }

    this.sendMessage(createMessage("file:search-done", {
      projectId: this.projectId,
      requestId: opts.requestId,
      totalMatches,
      totalFiles: filesWithMatches.size,
      duration: Date.now() - startTime,
      engine,
      error,
    }));

    // Identity-gated: a superseded run finishing after its successor started
    // must not clear the successor's handle, or `cancel` stops reaching it.
    if (!superseded) {
      this.activeProcess = null;
      this.activeRequestId = null;
    }
  }
}
