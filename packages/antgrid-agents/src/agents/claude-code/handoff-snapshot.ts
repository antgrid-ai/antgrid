import { lstat, open, readdir, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve, sep } from "node:path";
import {
  ByteBudget,
  SAFE_NATIVE_ID,
  copyWholeLines,
  refusesRealStoreUnderTest,
  type HandoffReference,
  type HandoffSnapshotFn,
  type HandoffSnapshotOpts,
} from "../handoff";
import { claudeProjectSlug } from "./transcript-read";

const CHUNK_BYTES = 256 * 1024;

/** CLAUDE_CONFIG_DIR relocates the whole store; ignoring it would miss every session of a user who set it. */
export function resolveClaudeProjectsRoot(seam: string | undefined, env: NodeJS.ProcessEnv = process.env): string {
  if (seam) return seam;
  const configDir = env.CLAUDE_CONFIG_DIR;
  return configDir ? join(configDir, "projects") : join(homedir(), ".claude", "projects");
}

async function isRegularFile(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isFile();
  } catch {
    return false;
  }
}

/** A resumed session copies the prior history in under a fresh id, so the file's
 * own id can first appear far from the top, and one of its records can be longer
 * than any fixed window. The basename already binds the file to the id; this only
 * rules out a file whose records never mention it. Read from the end, where the
 * file's own records are, matching raw bytes: Claude writes compact JSON, and a
 * quote inside a string value is escaped, so the needle can only be a record's
 * own field. */
async function namesSession(path: string, id: string): Promise<boolean> {
  const needle = Buffer.from(`"sessionId":${JSON.stringify(id)}`);
  try {
    const handle = await open(path, "r");
    try {
      let end = (await handle.stat()).size;
      // The head of the later chunk, so a needle split across a boundary still matches.
      let carry = Buffer.alloc(0);
      while (end > 0) {
        const start = Math.max(0, end - CHUNK_BYTES);
        const chunk = Buffer.alloc(end - start);
        const { bytesRead } = await handle.read(chunk, 0, chunk.length, start);
        const window = Buffer.concat([chunk.subarray(0, bytesRead), carry]);
        if (window.includes(needle)) return true;
        carry = window.subarray(0, needle.length - 1);
        end = start;
      }
    } finally {
      await handle.close();
    }
  } catch {
    return false;
  }
  return false;
}

/** A hook-supplied path is only a hint: any local process can post one, so it
 * counts only when it is `<root>/<project>/<id>.jsonl` after symlinks resolve. */
async function acceptHint(hint: string, root: string, id: string): Promise<string | undefined> {
  try {
    const realRoot = await realpath(root);
    const real = await realpath(hint);
    if (basename(real) !== `${id}.jsonl`) return undefined;
    if (dirname(dirname(real)) !== realRoot) return undefined;
    return (await isRegularFile(real)) && (await namesSession(real, id)) ? real : undefined;
  } catch {
    return undefined;
  }
}

async function locate(opts: HandoffSnapshotOpts, root: string, id: string): Promise<string | undefined> {
  if (opts.transcriptPath) {
    const hinted = await acceptHint(opts.transcriptPath, root, id);
    if (hinted) return hinted;
  }
  const slugs = [...new Set([claudeProjectSlug(resolve(opts.sourceCwd)), claudeProjectSlug(resolve(opts.projectPath))])];
  const dirs = [...slugs];
  try {
    for (const entry of await readdir(root, { withFileTypes: true })) {
      if (entry.isDirectory() && !slugs.includes(entry.name)) dirs.push(entry.name);
    }
  } catch {
    // No projects dir at all: nothing to find.
  }
  for (const dir of dirs) {
    const candidate = join(root, dir, `${id}.jsonl`);
    if ((await isRegularFile(candidate)) && (await namesSession(candidate, id))) return candidate;
  }
  return undefined;
}

async function isDirectory(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isDirectory();
  } catch {
    return false;
  }
}

export const snapshotClaudeTranscript: HandoffSnapshotFn = async (opts) => {
  if (refusesRealStoreUnderTest(opts.claudeProjectsRoot)) return undefined;
  const id = opts.agentSessionId;
  if (!id || !SAFE_NATIVE_ID.test(id)) return undefined;
  const root = resolveClaudeProjectsRoot(opts.claudeProjectsRoot);
  const source = await locate(opts, root, id);
  if (!source) return undefined;

  const budget = new ByteBudget(undefined, opts.signal);
  const file = await copyWholeLines(source, opts.outDir, "claude-code.jsonl", "transcript", budget);

  // Left in place: the main file names tool results by absolute path, and
  // subagent logs can be large.
  const references: HandoffReference[] = [];
  const sessionDir = join(dirname(source), id);
  if (await isDirectory(join(sessionDir, "subagents"))) {
    references.push({ path: `${sessionDir}${sep}subagents`, note: "Subagent transcripts of this session." });
  }
  if (await isDirectory(join(sessionDir, "tool-results"))) {
    references.push({ path: `${sessionDir}${sep}tool-results`, note: "Full tool outputs the transcript refers to by path." });
  }
  return {
    agent: "claude-code",
    agentSessionId: id,
    method: "copy",
    primary: file.name,
    files: [file],
    references,
    redactions: [],
    warnings: [],
  };
};
