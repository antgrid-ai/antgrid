import { readdirSync } from "node:fs";
import { readdir, realpath } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative } from "node:path";
import {
  HandoffSnapshotError,
  SAFE_NATIVE_ID,
  openMaybeZstd,
  withReadSnapshot,
  type RolloutSource,
} from "../handoff";
import { stateDbVersion } from "./title";

// The bridge's rollout-read.ts resolves a thread for live reading and is
// deliberately blind to `.zst` and `archived_sessions/`. A handoff needs the
// opposite: any representation of the rollout, so it resolves on its own.

const STORE_DIRS = ["sessions", "archived_sessions"] as const;
const SCAN_DEPTH = 5;
// Codex flips a rollout between .jsonl and .jsonl.zst in place; one short wait
// covers that window without turning a genuinely missing file into a stall.
const REPROBE_DELAY_MS = 100;
const FIRST_RECORD_CAP = 16 * 1024 * 1024;

/** `rollout-<ts>-<threadId>[_<rolloutId>]`, without either extension. */
function stemOf(path: string): string {
  return basename(path).replace(/\.zst$/, "").replace(/\.jsonl$/, "");
}

function isRolloutFile(name: string): boolean {
  return name.startsWith("rollout-") && /\.jsonl(\.zst)?$/.test(name);
}

/** A thread's own rollout: the original (`-<id>`) or any revision (`-<id>_<rid>`). */
function namesThread(stem: string, id: string): boolean {
  return stem.endsWith(`-${id}`) || stem.includes(`-${id}_`);
}

/** A lineage base is addressed by the id Codex wrote into `history_base`, which
 * is a thread id for an original file and a rollout id for a revision. */
function namesRollout(stem: string, id: string): boolean {
  return stem.endsWith(`-${id}`) || stem.endsWith(`_${id}`);
}

function within(parent: string, child: string): boolean {
  const rel = relative(parent, child);
  return rel !== "" && !rel.startsWith("..") && !isAbsolute(rel);
}

/** The file may exist only in its other spelling, so the directory is what gets
 * resolved: symlinks in the directory chain are the escape that matters. */
async function underStore(home: string, path: string): Promise<boolean> {
  try {
    const dir = await realpath(dirname(path));
    for (const store of STORE_DIRS) {
      let root: string;
      try {
        root = await realpath(join(home, store));
      } catch {
        continue;
      }
      if (dir === root || within(root, dir)) return true;
    }
  } catch {
    // an unresolvable directory is simply not a store path
  }
  return false;
}

function recordedRolloutPath(threadId: string, home: string): string | undefined {
  try {
    const newest = readdirSync(home)
      .filter((f) => stateDbVersion(f) >= 0)
      .sort((a, b) => stateDbVersion(b) - stateDbVersion(a))[0];
    if (!newest) return undefined;
    // No existence filter: the recorded path is always the plain spelling, which
    // is exactly the one that is gone once the rollout has been compressed.
    return withReadSnapshot(join(home, newest), (db) => {
      const row = db.query("SELECT rollout_path FROM threads WHERE id = ?").get(threadId) as { rollout_path?: unknown } | null;
      return typeof row?.rollout_path === "string" && row.rollout_path.trim() ? row.rollout_path.trim() : undefined;
    });
  } catch {
    // A locked or missing state database only demotes the lookup to the scan.
    return undefined;
  }
}

async function walk(dir: string, depth: number, signal: AbortSignal, out: string[]): Promise<void> {
  if (signal.aborted) throw new HandoffSnapshotError("UNREADABLE", "The handoff snapshot ran past its deadline.");
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    // Dirent never reports a symlink as a directory or file, so links are skipped.
    if (entry.isFile() && isRolloutFile(entry.name)) out.push(join(dir, entry.name));
    else if (entry.isDirectory() && depth < SCAN_DEPTH) await walk(join(dir, entry.name), depth + 1, signal, out);
  }
}

/** Plain-spelling candidates, newest first. The timestamp leads the name, so a
 * descending name sort is chronological. */
async function scan(home: string, matches: (stem: string) => boolean, signal: AbortSignal): Promise<string[]> {
  const found: string[] = [];
  for (const store of STORE_DIRS) await walk(join(home, store), 0, signal, found);
  const plain = new Set<string>();
  for (const path of found) {
    if (matches(stemOf(path))) plain.add(path.replace(/\.zst$/, ""));
  }
  return [...plain].sort((a, b) => basename(b).localeCompare(basename(a)) || b.localeCompare(a));
}

async function openWithReprobe(path: string): Promise<RolloutSource | undefined> {
  const first = await openMaybeZstd(path);
  if (first) return first;
  await Bun.sleep(REPROBE_DELAY_MS);
  return openMaybeZstd(path);
}

export interface LocateArgs {
  home: string;
  signal: AbortSignal;
}

/** The thread's current rollout: the state DB's path, then a hook-reported path
 * if it lies in the store, then a scan. */
export async function locateThreadRollout(
  threadId: string,
  hint: string | undefined,
  { home, signal }: LocateArgs,
): Promise<RolloutSource | undefined> {
  if (!SAFE_NATIVE_ID.test(threadId)) return undefined;

  const recorded = recordedRolloutPath(threadId, home);
  if (recorded && await underStore(home, recorded)) {
    const source = await openWithReprobe(recorded);
    if (source) return source;
  }
  // A hook can post any string, so a hint is trusted only for a file that is
  // in Codex's store and named for this thread.
  if (hint && namesThread(stemOf(hint), threadId) && isRolloutFile(basename(hint)) && await underStore(home, hint)) {
    const source = await openWithReprobe(hint.replace(/\.zst$/, ""));
    if (source) return source;
  }
  for (const candidate of await scan(home, (stem) => namesThread(stem, threadId), signal)) {
    const source = await openWithReprobe(candidate);
    if (source) return source;
  }
  return undefined;
}

/** The base file a `history_base` names. `visited` holds the plain paths already
 * in the chain, so a base that points back into it is reported as a cycle
 * instead of being followed forever. */
export async function locateBaseRollout(
  baseId: string,
  visited: ReadonlySet<string>,
  { home, signal }: LocateArgs,
): Promise<RolloutSource | undefined> {
  if (!SAFE_NATIVE_ID.test(baseId)) {
    throw new HandoffSnapshotError("UNREADABLE", "A Codex history base names an unsafe thread id.");
  }
  const candidates = await scan(home, (stem) => namesRollout(stem, baseId), signal);
  let cyclic = false;
  for (const candidate of candidates) {
    if (visited.has(candidate)) {
      cyclic = true;
      continue;
    }
    const source = await openWithReprobe(candidate);
    if (source) return source;
  }
  if (cyclic) throw new HandoffSnapshotError("UNREADABLE", "A Codex history base leads back into its own lineage.");
  return undefined;
}

/** Plain-spelling identity of an opened rollout, for cycle detection. */
export function rolloutKey(source: RolloutSource): string {
  return source.path.replace(/\.zst$/, "");
}

/** Line 1 of a rollout, which is `session_meta`. Never reads past FIRST_RECORD_CAP. */
export async function readFirstRecord(source: RolloutSource): Promise<unknown> {
  const parts: Buffer[] = [];
  let size = 0;
  for await (const chunk of source.open()) {
    const buf = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength);
    const newline = buf.indexOf(0x0a);
    const piece = newline < 0 ? buf : buf.subarray(0, newline);
    size += piece.length;
    if (size > FIRST_RECORD_CAP) throw new HandoffSnapshotError("UNREADABLE", "A Codex rollout's first record is implausibly large.");
    parts.push(piece);
    if (newline >= 0) break;
  }
  try {
    return JSON.parse(Buffer.concat(parts).toString("utf8"));
  } catch {
    return undefined;
  }
}

/** Decompressed length up to and including the last newline. */
export async function wholeLineLength(source: RolloutSource): Promise<number> {
  let position = 0;
  let end = 0;
  for await (const chunk of source.open()) {
    const last = Buffer.from(chunk.buffer, chunk.byteOffset, chunk.byteLength).lastIndexOf(0x0a);
    if (last >= 0) end = position + last + 1;
    position += chunk.length;
  }
  return end;
}
