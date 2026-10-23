import { lstat, readdir, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { z } from "zod";
import {
  ByteBudget, copyWholeLines, refusesRealStoreUnderTest, SAFE_NATIVE_ID, writeText,
  type HandoffFile, type HandoffReference, type HandoffSnapshotFn,
} from "../handoff";

// meta.json embeds the whole config, tool schemas and system prompt, so a few
// hundred KB is normal; past this it is not the file Vibe writes.
const MAX_META_BYTES = 8 * 1024 * 1024;
// Session directory names start with a UTC timestamp, so newest-first by name
// bounds the working-directory scan without statting every directory.
const MAX_SCANNED_SESSIONS = 500;

const Meta = z.object({
  session_id: z.string().optional(),
  start_time: z.unknown().optional(),
  end_time: z.unknown().optional(),
  origin_directory: z.unknown().optional(),
  total_messages: z.unknown().optional(),
  environment: z.object({ working_directory: z.string().optional() }).passthrough().optional(),
}).passthrough();
type Meta = z.infer<typeof Meta>;

const isDirectory = (path: string) => lstat(path).then((info) => info.isDirectory(), () => false);
const isFile = (path: string) => lstat(path).then((info) => info.isFile(), () => false);

async function readMeta(dir: string): Promise<Meta | undefined> {
  const path = join(dir, "meta.json");
  try {
    const info = await lstat(path);
    if (!info.isFile() || info.size > MAX_META_BYTES) return undefined;
    return Meta.parse(JSON.parse(await readFile(path, "utf8")));
  } catch {
    return undefined;
  }
}

function sameDirectory(a: string, b: string): boolean {
  const [x, y] = [resolve(a), resolve(b)];
  return process.platform === "win32" ? x.toLowerCase() === y.toLowerCase() : x === y;
}

/** A hook-supplied path is a hint: it counts only when it is the messages file
 * of a session directory directly under the save dir whose meta names the id. */
async function hintedSessionDir(saveDir: string, hint: string | undefined, id: string): Promise<string | undefined> {
  if (!hint) return undefined;
  try {
    const real = await realpath(hint);
    const dir = dirname(real);
    if (basename(real) !== "messages.jsonl" || dirname(dir) !== saveDir) return undefined;
    if (!basename(dir).endsWith(`_${id.slice(0, 8)}`)) return undefined;
    return (await readMeta(dir))?.session_id === id ? dir : undefined;
  } catch {
    return undefined;
  }
}

async function sessionDirs(saveDir: string): Promise<string[]> {
  const names = await readdir(saveDir).catch(() => [] as string[]);
  return names.filter((name) => !name.startsWith(".")).sort().reverse().map((name) => join(saveDir, name));
}

async function idSessionDir(saveDir: string, id: string): Promise<string | undefined> {
  const suffix = `_${id.slice(0, 8)}`;
  for (const dir of await sessionDirs(saveDir)) {
    if (!basename(dir).endsWith(suffix) || !(await isDirectory(dir))) continue;
    if ((await readMeta(dir))?.session_id === id) return dir;
  }
  return undefined;
}

/** Only for a session whose identity was never captured: it counts when exactly
 * one session in the store ran in the source directory, because choosing among
 * several would hand the wrong conversation to the target. One that started
 * before the source row existed cannot be its own, so it is not a candidate. */
async function uniqueDirectorySession(saveDir: string, sourceCwd: string, notBefore: number | undefined): Promise<{ dir: string; id: string } | undefined> {
  let found: { dir: string; id: string } | undefined;
  for (const dir of (await sessionDirs(saveDir)).slice(0, MAX_SCANNED_SESSIONS)) {
    const meta = await readMeta(dir);
    const cwd = meta?.environment?.working_directory;
    if (!meta?.session_id || !cwd || !sameDirectory(cwd, sourceCwd)) continue;
    if (notBefore !== undefined && !(Date.parse(String(meta.start_time)) >= notBefore)) continue;
    if (found) return undefined;
    found = { dir, id: meta.session_id };
  }
  return found;
}

function allowlistedMeta(meta: Meta): Record<string, unknown> {
  const kept: Record<string, unknown> = {};
  for (const key of ["session_id", "start_time", "end_time"] as const) if (meta[key] !== undefined) kept[key] = meta[key];
  if (meta.environment?.working_directory !== undefined) kept.environment = { working_directory: meta.environment.working_directory };
  for (const key of ["origin_directory", "total_messages"] as const) if (meta[key] !== undefined) kept[key] = meta[key];
  return kept;
}

export const snapshotVibe: HandoffSnapshotFn = async (opts) => {
  if (refusesRealStoreUnderTest(opts.vibeHome)) return undefined;
  const id = opts.agentSessionId;
  if (id !== undefined && !SAFE_NATIVE_ID.test(id)) return undefined;
  // An explicit home wins over the environment so a test or a relocated store
  // is never shadowed by the developer's own save-dir override.
  const configured = opts.vibeHome !== undefined
    ? join(opts.vibeHome, "logs", "session")
    : process.env.VIBE_SESSION_LOGGING__SAVE_DIR
      ?? join(process.env.VIBE_HOME ?? join(homedir(), ".vibe"), "logs", "session");
  let saveDir: string;
  try {
    saveDir = await realpath(configured);
  } catch {
    return undefined;
  }

  let dir: string | undefined;
  let resolvedId = id;
  if (id) {
    dir = await hintedSessionDir(saveDir, opts.transcriptPath, id) ?? await idSessionDir(saveDir, id);
  } else {
    const match = await uniqueDirectorySession(saveDir, opts.sourceCwd, opts.sourceCreatedAt);
    dir = match?.dir;
    resolvedId = match?.id;
  }
  if (!dir) return undefined;
  const messages = join(dir, "messages.jsonl");
  if (!(await isFile(messages))) return undefined;
  const meta = await readMeta(dir);

  const budget = new ByteBudget(undefined, opts.signal);
  const files: HandoffFile[] = [await copyWholeLines(messages, opts.outDir, "vibe-messages.jsonl", "transcript", budget)];
  if (meta) {
    files.push(await writeText(opts.outDir, "vibe-meta.json", `${JSON.stringify(allowlistedMeta(meta), null, 2)}\n`, "sidecar", budget));
  }
  const references: HandoffReference[] = [];
  if (await isDirectory(join(dir, "agents"))) {
    references.push({ path: join(dir, "agents"), note: "Subagent sessions, each with its own messages.jsonl." });
  }
  if (await isDirectory(join(dir, "attachments"))) {
    references.push({ path: join(dir, "attachments"), note: "Images the messages name by absolute path." });
  }
  return {
    agent: "mistral-vibe",
    ...(resolvedId ? { agentSessionId: resolvedId } : {}),
    method: "copy",
    primary: "vibe-messages.jsonl",
    files,
    references,
    redactions: ["meta.json (kept session_id, start_time, end_time, environment.working_directory, origin_directory, total_messages; dropped the config dump, system prompt and tool schemas)"],
    warnings: meta ? [] : ["Vibe's meta.json could not be read, so the session details were left out."],
  };
};
