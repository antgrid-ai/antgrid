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

const HEAD_BYTES = 256 * 1024;

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

/** The first record that names a session must name this one: a file whose
 * records belong to another conversation is never ours, whatever its basename says. */
async function namesSession(path: string, id: string): Promise<boolean> {
  let head: string;
  try {
    const handle = await open(path, "r");
    try {
      const buffer = Buffer.alloc(HEAD_BYTES);
      const { bytesRead } = await handle.read(buffer, 0, HEAD_BYTES, 0);
      head = buffer.subarray(0, bytesRead).toString("utf8");
    } finally {
      await handle.close();
    }
  } catch {
    return false;
  }
  for (const line of head.split("\n")) {
    if (!line.trim()) continue;
    let record: { sessionId?: unknown };
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (typeof record?.sessionId === "string") return record.sessionId === id;
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
