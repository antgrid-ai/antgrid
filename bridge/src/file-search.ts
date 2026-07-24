import { createMessage, type AbMessage } from "./protocol";
import { logger } from "./logger";
const log = logger.child({ component: "file-search" });

type SearchEngine = "ripgrep" | "git-grep";

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

interface SearchMatchData {
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
const GIT_GREP_MATCH_RE = /^(.+?):(\d+):(\d+):(.*)$/;
const GIT_GREP_CONTEXT_RE = /^(.+?)-(\d+)-(.*)$/;

function buildRipgrepArgs(opts: SearchOptions, projectPath: string): string[] {
  const args = ["rg", "--json", "-n", "--column", "-C", "2"];
  if (!opts.caseSensitive) args.push("-i");
  if (opts.wholeWord) args.push("-w");
  if (!opts.regex) args.push("-F");
  args.push("--", opts.query, projectPath);
  return args;
}

function buildGitGrepArgs(opts: SearchOptions, projectPath: string): string[] {
  const args = ["git", "-C", projectPath, "grep", "-n", "--column", "-C", "2", "--untracked"];
  if (!opts.caseSensitive) args.push("-i");
  if (opts.wholeWord) args.push("-w");
  if (opts.regex) args.push("-P");
  else args.push("-F");
  args.push("-e", opts.query, "--", ".");
  return args;
}

export class FileSearcher {
  private projectRoot: string;
  private projectId: string;
  private sendMessage: (msg: AbMessage) => void;
  private activeProcess: ReturnType<typeof Bun.spawn> | null = null;
  private activeRequestId: string | null = null;

  constructor(
    projectRoot: string,
    projectId: string,
    sendMessage: (msg: AbMessage) => void,
  ) {
    this.projectRoot = projectRoot;
    this.projectId = projectId;
    this.sendMessage = sendMessage;
  }

  cancel(requestId: string): void {
    if (this.activeRequestId === requestId && this.activeProcess) {
      this.activeProcess.kill();
      this.activeProcess = null;
      this.activeRequestId = null;
    }
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

    const args = engine === "ripgrep"
      ? buildRipgrepArgs(opts, this.projectRoot)
      : buildGitGrepArgs(opts, this.projectRoot);

    const proc = Bun.spawn(args, {
      stdout: "pipe",
      stderr: "pipe",
      cwd: this.projectRoot,
    });
    this.activeProcess = proc;

    const batch: SearchMatchData[] = [];
    const filesWithMatches = new Set<string>();
    let totalMatches = 0;
    let truncated = false;
    let batchTimer: ReturnType<typeof setTimeout> | null = null;

    const timeout = setTimeout(() => {
      proc.kill();
    }, TIMEOUT_MS);

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

    const stdout = proc.stdout;
    const reader = stdout.getReader();
    const decoder = new TextDecoder();
    let leftover = "";

    let contextAccum: { before: string[]; matchLine: SearchMatchData | null; afterCount: number } = {
      before: [],
      matchLine: null,
      afterCount: 0,
    };

    const flushContextMatch = () => {
      if (contextAccum.matchLine) {
        addMatch(contextAccum.matchLine);
        contextAccum.matchLine = null;
      }
    };

    const processRipgrepLine = (line: string) => {
      try {
        const obj = JSON.parse(line);
        if (obj.type === "context") {
          const data = obj.data;
          let lineText = data.lines?.text ?? "";
          if (lineText.endsWith("\n")) lineText = lineText.slice(0, -1);
          if (contextAccum.matchLine && contextAccum.afterCount < 2) {
            contextAccum.matchLine.contextAfter.push(lineText);
            contextAccum.afterCount++;
          } else {
            contextAccum.before.push(lineText);
            if (contextAccum.before.length > 2) contextAccum.before.shift();
          }
        } else if (obj.type === "match") {
          flushContextMatch();
          const data = obj.data;
          const relPath = data.path?.text ?? "";
          const lineNum = data.line_number ?? 0;
          const col = data.submatches?.[0]?.start ?? 0;
          let lineText = data.lines?.text ?? "";
          if (lineText.endsWith("\n")) lineText = lineText.slice(0, -1);
          if (lineText.length > MAX_LINE_LENGTH) lineText = lineText.slice(0, MAX_LINE_LENGTH);
          contextAccum.matchLine = {
            path: relPath,
            line: lineNum,
            column: col + 1,
            lineContent: lineText,
            contextBefore: [...contextAccum.before],
            contextAfter: [],
          };
          contextAccum.before = [];
          contextAccum.afterCount = 0;
        } else if (obj.type === "begin" || obj.type === "end") {
          // File boundary — flush pending match and reset context
          flushContextMatch();
          contextAccum.before = [];
          contextAccum.afterCount = 0;
        }
      } catch {}
    };

    const processGitGrepLine = (line: string) => {
      if (line === "--") {
        flushContextMatch();
        contextAccum.before = [];
        contextAccum.afterCount = 0;
        return;
      }

      const matchResult = GIT_GREP_MATCH_RE.exec(line);
      if (matchResult) {
        flushContextMatch();
        let lineContent = matchResult[4];
        if (lineContent.length > MAX_LINE_LENGTH) lineContent = lineContent.slice(0, MAX_LINE_LENGTH);
        contextAccum.matchLine = {
          path: matchResult[1],
          line: parseInt(matchResult[2], 10),
          column: parseInt(matchResult[3], 10),
          lineContent,
          contextBefore: [...contextAccum.before],
          contextAfter: [],
        };
        contextAccum.before = [];
        contextAccum.afterCount = 0;
        return;
      }

      const contextResult = GIT_GREP_CONTEXT_RE.exec(line);
      if (contextResult) {
        const content = contextResult[3];
        if (contextAccum.matchLine && contextAccum.afterCount < 2) {
          contextAccum.matchLine.contextAfter.push(content);
          contextAccum.afterCount++;
        } else {
          contextAccum.before.push(content);
          if (contextAccum.before.length > 2) contextAccum.before.shift();
        }
      }
    };

    const processLine = engine === "ripgrep" ? processRipgrepLine : processGitGrepLine;

    try {
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        const text = leftover + decoder.decode(value, { stream: true });
        const lines = text.split("\n");
        leftover = lines.pop() ?? "";
        for (const line of lines) {
          if (line.trim()) processLine(line);
        }
      }
      if (leftover.trim()) processLine(leftover);
      flushContextMatch();
    } catch {}

    clearTimeout(timeout);
    if (batchTimer) {
      clearTimeout(batchTimer);
      batchTimer = null;
    }
    flushBatch();

    await proc.exited;

    this.sendMessage(createMessage("file:search-done", {
      projectId: this.projectId,
      requestId: opts.requestId,
      totalMatches,
      totalFiles: filesWithMatches.size,
      duration: Date.now() - startTime,
      engine,
      error: truncated ? `Results truncated at ${MAX_RESULTS} matches` : undefined,
    }));

    this.activeProcess = null;
    this.activeRequestId = null;
  }
}
