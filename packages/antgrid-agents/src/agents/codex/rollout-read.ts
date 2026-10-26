// bridge/src/agents/codex/rollout-read.ts
import { Database } from "bun:sqlite";
import { existsSync, readdirSync } from "node:fs";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";
import { readTailUntil } from "../../transcript-tail";
import { codexHomeDir } from "./home";
import { stateDbVersion } from "./title";

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

const ZST = ".zst";

async function entriesDesc(path: string): Promise<string[]> {
  try {
    return (await readdir(path)).sort((a, b) => b.localeCompare(a));
  } catch {
    return [];
  }
}

/**
 * The thread's current rollout as Codex itself records it. A rolled-back thread
 * continues in a new rollout-<ts>-<threadId>_<rolloutId>.jsonl while its old
 * file stays on disk as the history base, so a filename match — and above all
 * a cached one — can name a file Codex no longer appends to.
 */
function rolloutPathFromStateDb(threadId: string, home: string): string | undefined {
  let db: Database | null = null;
  try {
    const newest = readdirSync(home)
      .filter((f) => stateDbVersion(f) >= 0)
      .sort((a, b) => stateDbVersion(b) - stateDbVersion(a))[0];
    if (!newest) return undefined;
    db = new Database(join(home, newest), { readonly: true });
    // Synchronous on the bridge's loop: never wait on codex's write lock.
    db.exec("PRAGMA busy_timeout = 0");
    const row = db.query("SELECT rollout_path FROM threads WHERE id = ?").get(threadId) as { rollout_path?: string | null } | null;
    const path = row?.rollout_path?.trim();
    if (!path) return undefined;
    if (existsSync(path)) return path;
    // Codex compresses a rollout idle for about a week to <path>.zst and leaves
    // the row naming the .jsonl it replaced.
    const compressed = `${path}${ZST}`;
    return existsSync(compressed) ? compressed : undefined;
  } catch {
    return undefined;
  } finally {
    db?.close();
  }
}

/**
 * Rollout file for a thread: the path codex's state DB records, else a scan of
 * sessions/<YYYY>/<MM>/<DD>/rollout-<ts>-<threadId>[_<rolloutId>].jsonl, newest
 * date dirs and names first (zero-padded, so lexicographic desc is chronological
 * desc). Either may be a compressed .jsonl.zst: a fork or handoff of a session
 * idle for a week reads one. archived_sessions/ is deliberately not searched.
 * Never throws.
 */
export async function findCodexRolloutPath(threadId: string, codexHome?: string): Promise<string | undefined> {
  const home = codexHome ?? codexHomeDir();
  const recorded = rolloutPathFromStateDb(threadId, home);
  if (recorded) return recorded;
  const cacheKey = `${home}\0${threadId}`;
  const cached = resolvedPaths.get(cacheKey);
  if (cached && existsSync(cached)) return cached;
  const sessions = join(home, "sessions");
  const exact = `-${threadId}.jsonl`;
  const revision = `-${threadId}_`;
  const isRollout = (f: string) => f.endsWith(exact) || (f.includes(revision) && f.endsWith(".jsonl"));
  for (const y of await entriesDesc(sessions)) {
    for (const m of await entriesDesc(join(sessions, y))) {
      for (const d of await entriesDesc(join(sessions, y, m))) {
        for (const f of await entriesDesc(join(sessions, y, m, d))) {
          if (f.endsWith(ZST) && isRollout(f.slice(0, -ZST.length))) {
            // Sorts ahead of a plain sibling, which only a resume rewrites and
            // which is then the live file. Not cached: the resume can follow.
            const plain = join(sessions, y, m, d, f.slice(0, -ZST.length));
            return existsSync(plain) ? plain : join(sessions, y, m, d, f);
          }
          if (isRollout(f)) {
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
 * event_msg lines: they carry what was actually typed and said, while their
 * response_item twins duplicate the text plus injected context
 * (<environment_context>, AGENTS.md dumps) as fake user turns — taking one side
 * is also what prevents double-counting. Paginated rollouts (codex 0.16x, and
 * every older file its migration rewrote) record messages as item_completed
 * UserMessage/AgentMessage items; legacy rollouts as user_message/agent_message.
 * Unknown line types (codex writes variants newer than any reader, e.g.
 * world_state) and torn lines are skipped, matching codex's own tolerant
 * loader. Never throws.
 */
export async function readLastCodexMessages(path: string, n: number): Promise<string[]> {
  if (n <= 0) return []; // slice(-0) === slice(0) — the whole array, not none
  if (path.endsWith(ZST)) {
    // A zstd frame has no tail to seek to, and a cold rollout no longer grows.
    try {
      const raw = new TextDecoder().decode(await Bun.zstdDecompress(await readFile(path)));
      return codexMessagesIn(raw).slice(-n);
    } catch {
      return [];
    }
  }
  // Widened until it HAS n — same bound, same reason, as the Claude reader. A
  // rollout interleaves its conversation with response_item twins and tool
  // traffic this drops, so the share of a byte window that survives to here is
  // small and varies by session.
  return (await readTailUntil(path, n, codexMessagesIn, { keepOversized: readsLine })).slice(-n);
}

// The first "type" in a rollout line is its own; only timestamp and ordinal
// come before it. A compaction checkpoint carries the history it replaces, so
// it can be oversized and must still be read to reset the list.
const LINE_TYPE = /"type":"([a-z_]+)"/;
const readsLine = (head: string) => {
  const type = LINE_TYPE.exec(head)?.[1];
  return type === "compacted" || type === "event_msg";
};

function codexMessagesIn(raw: string): string[] {
  let out: string[] = [];
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let obj: any;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj?.type === "compacted") {
      // History before a compaction left the model's context; what the
      // checkpoint carries forward is the surviving base.
      out = compactedBase(obj.payload);
      continue;
    }
    if (obj?.type !== "event_msg") continue;
    const p = obj.payload;
    if (p?.type === "item_completed") {
      const item = p.item;
      if (item?.type === "UserMessage") {
        const text = withoutRequestWrapper(itemText(item));
        if (text) out.push(text);
      } else if (item?.type === "AgentMessage") {
        const text = itemText(item).trim();
        if (text) out.push(text);
      }
    } else if (p?.type === "user_message" && typeof p.message === "string") {
      const text = withoutRequestWrapper(p.message);
      if (text) out.push(text);
    } else if (p?.type === "agent_message" && typeof p.message === "string") {
      const text = p.message.trim();
      if (text) out.push(text);
    }
  }
  return out;
}

/** The turns a compaction checkpoint keeps verbatim in retained_context, user
 * and assistant lists apart, so `order` (the thread-wide sequence) restores
 * the interleaving. */
export function retainedTurns(payload: any): { role: "user" | "assistant"; text: string }[] {
  const retained = payload?.retained_context;
  const entries = (list: unknown, role: "user" | "assistant") =>
    (Array.isArray(list) ? list : [])
      .filter((m: any) => typeof m?.text === "string" && typeof m?.order === "number")
      .map((m: any) => ({ order: m.order as number, role, text: role === "user" ? withoutRequestWrapper(m.text) : m.text.trim() }));
  return [...entries(retained?.user_messages, "user"), ...entries(retained?.assistant_messages, "assistant")]
    .sort((a, b) => a.order - b.order)
    .filter((e) => e.text)
    .map(({ role, text }) => ({ role, text }));
}

// Injected user-role messages (AGENTS.md dumps, environment context, plugin
// lists) are not something the user said.
const INJECTED_USER_TEXT = /^\s*(?:<|# AGENTS)/;
export const isInjectedUserText = (text: string) => INJECTED_USER_TEXT.test(text);

/** The user's own messages from a checkpoint's replacement_history, the only
 * plaintext an older checkpoint (empty `message`, no retained turns) keeps:
 * its summary item is encrypted and its agent_message entries are traffic
 * between sub-agents, not replies to the user. */
export function replacementUserTexts(payload: any): string[] {
  if (!Array.isArray(payload?.replacement_history)) return [];
  const texts: string[] = [];
  for (const entry of payload.replacement_history) {
    if (entry?.type !== "message" || entry.role !== "user" || !Array.isArray(entry.content)) continue;
    const raw = entry.content.map((part: any) => (typeof part?.text === "string" ? part.text : "")).join("");
    if (isInjectedUserText(raw)) continue;
    const text = withoutRequestWrapper(raw);
    if (text) texts.push(text);
  }
  return texts;
}

// Legacy checkpoints carry a summary in `message`. Later ones leave it empty
// and keep the recent turns in retained_context (codex 0.162 and later at
// least); those in between keep only the user's messages, in
// replacement_history.
function compactedBase(payload: any): string[] {
  const summary = typeof payload?.message === "string" ? payload.message.trim() : "";
  if (summary) return [summary];
  const turns = retainedTurns(payload);
  if (turns.length > 0) return turns.map((turn) => turn.text);
  return replacementUserTexts(payload);
}

export function withoutRequestWrapper(message: string): string {
  const idx = message.indexOf(USER_MESSAGE_BEGIN);
  return (idx >= 0 ? message.slice(idx + USER_MESSAGE_BEGIN.length) : message).trim();
}

// A long user message arrives split across several text parts, each carrying
// its own line breaks, so the parts are joined with nothing between them.
// UserMessage spells the part type "text", AgentMessage "Text"; images
// (local_image) carry no text and are dropped.
function itemText(item: any): string {
  if (!Array.isArray(item?.content)) return "";
  return item.content
    .filter((part: any) => typeof part?.text === "string" && String(part.type).toLowerCase() === "text")
    .map((part: any) => part.text)
    .join("");
}
