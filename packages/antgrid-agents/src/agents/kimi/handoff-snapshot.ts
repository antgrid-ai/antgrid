import { lstat, readdir, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve, sep } from "node:path";
import { z } from "zod";
import {
  ByteBudget, copyWholeLines, refusesRealStoreUnderTest, SAFE_NATIVE_ID, writeText,
  type HandoffFile, type HandoffReference, type HandoffSnapshot, type HandoffSnapshotFn,
} from "../handoff";

const IndexRecord = z.object({
  sessionId: z.string(),
  sessionDir: z.string().optional(),
  deleted: z.boolean().optional(),
});
// state.json is a few KB of titles and flags; anything bigger is not that file.
const MAX_STATE_BYTES = 1024 * 1024;

const isFile = (path: string) => lstat(path).then((info) => info.isFile(), () => false);
const isDirectory = (path: string) => lstat(path).then((info) => info.isDirectory(), () => false);

async function within(root: string, path: string): Promise<string | undefined> {
  try {
    const real = await realpath(path);
    return real.startsWith(root + sep) ? real : undefined;
  } catch {
    return undefined;
  }
}

/** The last index record wins and a tombstone is final: a deleted session must
 * not be resurrected by the directory glob, which would still find its files. */
async function indexedSessionDir(home: string, id: string): Promise<string | "deleted" | undefined> {
  let text: string;
  try {
    text = await readFile(join(home, "session_index.jsonl"), "utf8");
  } catch {
    return undefined;
  }
  let found: z.infer<typeof IndexRecord> | undefined;
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let record: z.infer<typeof IndexRecord>;
    try {
      record = IndexRecord.parse(JSON.parse(line));
    } catch {
      continue;
    }
    if (record.sessionId === id) found = record;
  }
  if (found?.deleted) return "deleted";
  return found?.sessionDir;
}

async function globbedSessionDir(home: string, id: string): Promise<string | undefined> {
  const sessions = join(home, "sessions");
  const workdirs = await readdir(sessions).catch(() => [] as string[]);
  for (const workdir of workdirs) {
    const candidate = join(sessions, workdir, id);
    if (await isDirectory(candidate)) return candidate;
  }
  return undefined;
}

async function referencesFor(sessionDir: string): Promise<HandoffReference[]> {
  const references: HandoffReference[] = [];
  const agents = join(sessionDir, "agents");
  for (const name of await readdir(agents).catch(() => [] as string[])) {
    const dir = join(agents, name);
    if (name === "main") {
      const results = join(dir, "tool-results");
      if (await isDirectory(results)) references.push({ path: results, note: "Tool output the main agent's log refers to by absolute path." });
    } else if (await isDirectory(dir)) {
      references.push({ path: dir, note: "A subagent's own log; the main log holds only its call and result." });
    }
  }
  const results = join(sessionDir, "tool-results");
  if (await isDirectory(results)) references.push({ path: results, note: "Tool output the main agent's log refers to by absolute path." });
  return references;
}

export const snapshotKimi: HandoffSnapshotFn = async (opts) => {
  if (refusesRealStoreUnderTest(opts.kimiHome)) return undefined;
  const id = opts.agentSessionId;
  if (!id || !SAFE_NATIVE_ID.test(id)) return undefined;
  let home: string;
  try {
    home = await realpath(opts.kimiHome ?? process.env.KIMI_CODE_HOME ?? join(homedir(), ".kimi-code"));
  } catch {
    return undefined;
  }

  const indexed = await indexedSessionDir(home, id);
  if (indexed === "deleted") return undefined;
  // The index is the agent's own record but it is still a path read from disk.
  const dir = (indexed && await within(home, resolve(indexed))) ?? (await globbedSessionDir(home, id));
  const sessionDir = dir && await within(home, dir);
  if (!sessionDir) return undefined;
  const wire = await within(home, join(sessionDir, "agents", "main", "wire.jsonl"));
  if (!wire || !(await isFile(wire))) return undefined;

  const budget = new ByteBudget(undefined, opts.signal);
  const files: HandoffFile[] = [];
  const warnings: string[] = [];
  const transcript = await copyWholeLines(wire, opts.outDir, "kimi-wire.jsonl", "transcript", budget);
  files.push(transcript);

  const state = join(sessionDir, "state.json");
  if (await isFile(state)) {
    try {
      const text = await readFile(state, "utf8");
      if (text.length > MAX_STATE_BYTES) throw new Error("too large");
      JSON.parse(text);
      files.push({ ...(await writeText(opts.outDir, "kimi-state.json", text, "sidecar", budget)), sourcePath: state });
    } catch {
      warnings.push("Kimi's state.json could not be read, so the session title and flags were left out.");
    }
  }

  return {
    agent: "kimi",
    agentSessionId: id,
    method: "copy",
    primary: transcript.name,
    files,
    references: await referencesFor(sessionDir),
    redactions: [],
    warnings,
  } satisfies HandoffSnapshot;
};
