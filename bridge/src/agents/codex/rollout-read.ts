// bridge/src/agents/codex/rollout-read.ts
import { existsSync } from "node:fs";
import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { readTranscriptTail } from "../../transcript-tail";
import { codexHomeDir } from "./home";

// codex wraps typed input in a contextual template; everything before this
// marker is injected scaffolding, not the user's words (codex-rs protocol.rs
// USER_MESSAGE_BEGIN — codex's own extractors strip it the same way).
const USER_MESSAGE_BEGIN = "## My request for Codex:";

// Resolved rollout paths, keyed by (home, threadId) so test fixtures with
// reused thread ids never cross homes. A live rollout never moves (archiving
// and .zst compression only touch cold sessions), so a hit needs only an
// existence re-check. Misses are deliberately not cached: codex defers file
// creation for new threads, so a miss may become a hit on the next call.
const resolvedPaths = new Map<string, string>();
const RESOLVED_CACHE_CAP = 200;

async function entriesDesc(path: string): Promise<string[]> {
  try {
    return (await readdir(path)).sort((a, b) => b.localeCompare(a));
  } catch {
    return [];
  }
}

/**
 * Rollout file for a thread: sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<threadId>.jsonl,
 * searched newest date dirs first (zero-padded names, so lexicographic desc is
 * chronological desc). archived_sessions/ and .zst siblings are deliberately not
 * searched: a session under live supervision is neither archived nor cold enough
 * to be compressed. Never throws.
 */
export async function findCodexRolloutPath(threadId: string, codexHome?: string): Promise<string | undefined> {
  const home = codexHome ?? codexHomeDir();
  const cacheKey = `${home}\0${threadId}`;
  const cached = resolvedPaths.get(cacheKey);
  if (cached && existsSync(cached)) return cached;
  const sessions = join(home, "sessions");
  const suffix = `-${threadId}.jsonl`;
  for (const y of await entriesDesc(sessions)) {
    for (const m of await entriesDesc(join(sessions, y))) {
      for (const d of await entriesDesc(join(sessions, y, m))) {
        for (const f of await entriesDesc(join(sessions, y, m, d))) {
          if (f.endsWith(suffix)) {
            const path = join(sessions, y, m, d, f);
            if (resolvedPaths.size >= RESOLVED_CACHE_CAP) {
              resolvedPaths.delete(resolvedPaths.keys().next().value!);
            }
            resolvedPaths.set(cacheKey, path);
            return path;
          }
        }
      }
    }
  }
  return undefined;
}

/**
 * Last n conversation texts from a codex rollout, chronological. Reads only
 * event_msg lines: user_message/agent_message carry what was actually typed and
 * said, while their response_item twins duplicate the text plus injected
 * context (<environment_context>, AGENTS.md dumps) as fake user turns — taking
 * one side is also what prevents double-counting. Unknown line types (codex
 * writes variants newer than any reader, e.g. world_state) and torn lines are
 * skipped, matching codex's own tolerant loader. Never throws.
 */
export async function readLastCodexMessages(path: string, n: number): Promise<string[]> {
  if (n <= 0) return []; // slice(-0) === slice(0) — the whole array, not none
  const raw = await readTranscriptTail(path);
  if (!raw) return [];
  let out: string[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let obj: any;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj?.type === "compacted") {
      // History before a compaction left the model's context; the summary
      // (often empty) is the surviving base.
      out = [];
      const summary = typeof obj?.payload?.message === "string" ? obj.payload.message.trim() : "";
      if (summary) out.push(summary);
      continue;
    }
    if (obj?.type !== "event_msg") continue;
    const p = obj.payload;
    if (p?.type === "user_message" && typeof p.message === "string") {
      const idx = p.message.indexOf(USER_MESSAGE_BEGIN);
      const text = (idx >= 0 ? p.message.slice(idx + USER_MESSAGE_BEGIN.length) : p.message).trim();
      if (text) out.push(text);
    } else if (p?.type === "agent_message" && typeof p.message === "string") {
      const text = p.message.trim();
      if (text) out.push(text);
    }
  }
  return out.slice(-n);
}
