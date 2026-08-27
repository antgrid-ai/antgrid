import { Database } from "bun:sqlite";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ResolvedTitle } from "../types";
import { firstMessage, generated, readOrNull } from "../title-read";

/**
 * Antigravity transcript title: first `type:"USER_INPUT"` line's `content`,
 * stripped of the `<USER_REQUEST>...</USER_REQUEST>` wrapper (and any appended
 * `<ADDITIONAL_METADATA>`/`<USER_SETTINGS_CHANGE>` blocks) it's wrapped in.
 * Falls back to the raw content for any shape that doesn't match — the wrapper
 * format is observed, not documented. Resolved bridge-side rather than in the
 * hook script itself: the hook runs under bare `node`, which has no reliable
 * sqlite reader for agy's global conversation_summaries.db (confirmed NOT
 * populated during a live CLI session, even after a clean exit), so
 * transcriptPath — handed to us directly on every hook payload — is the only
 * reliable source. See plugin/antigravity/post-title.js and ./hooks.ts.
 */
function extractAntigravityTitle(content: unknown): string | null {
  if (typeof content !== "string") return null;
  const m = /<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/.exec(content);
  const text = (m ? m[1] : content).trim();
  return text || null;
}

/** Absolute path to agy's CLI home (`~/.gemini/antigravity-cli`), where the
 *  global command `history.jsonl` and per-conversation `brain/<id>` dirs live.
 *  The `/rename` slash command is logged here — the only live source for a
 *  user-chosen conversation title (conversation_summaries.db is IDE-written and
 *  stale for CLI sessions). */
export function antigravityCliHome(): string {
  return join(homedir(), ".gemini", "antigravity-cli");
}

/** The `<name>` from a `/rename <name>` history entry, or null for a bare
 *  `/rename` (no argument) or a non-rename display string. */
function renameArg(display: unknown): string | null {
  if (typeof display !== "string") return null;
  const m = /^\/rename\s+([\s\S]+)$/.exec(display.trim());
  return m ? m[1].trim() || null : null;
}

/**
 * Latest user-chosen title per conversationId from agy's global command log.
 * Every command agy runs is appended to history.jsonl as
 * `{display, conversationId, type:"slash_command"}`; a `/rename <name>` line is
 * the user's manual title (direct analogue of Claude's `custom-title`). Last
 * matching line wins; a bare `/rename` (no arg) is not a title and does not
 * clear a prior one. Pure (no I/O) so the same parse feeds both the resolver
 * and the live rename watcher.
 */
export function parseAntigravityRenames(raw: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    let obj: any;
    try { obj = JSON.parse(t); } catch { continue; }
    if (obj?.type !== "slash_command") continue;
    const cid = obj?.conversationId;
    if (typeof cid !== "string" || !cid) continue;
    const name = renameArg(obj.display);
    if (name) out.set(cid, name); // later line overwrites → latest wins
  }
  return out;
}

/**
 * agy's own conversation names, keyed by conversationId, from the global
 * `conversation_summaries.db`: the manual `title` (its copy of the user's
 * `/rename`) if set, else the model-generated `preview` (e.g. "Casual Greeting
 * And Introduction"). Fully-empty rows (a brand-new conversation agy hasn't
 * named yet) are omitted so the caller falls through to the first user message.
 *
 * agy writes this DB asynchronously AFTER a turn (WAL mode), so it's the lagging
 * upgrade path, not the instant one — history.jsonl carries a `/rename` live.
 * Opened read-only with busy_timeout=0 (never wait on agy's write lock); any
 * error (locked, missing, schema drift) yields an empty map. Mirrors the codex/
 * copilot sqlite title readers.
 */
export function readAntigravitySummaries(antigravityHome: string): Map<string, string> {
  const out = new Map<string, string>();
  let db: Database | null = null;
  try {
    db = new Database(join(antigravityHome, "conversation_summaries.db"), { readonly: true });
    db.exec("PRAGMA busy_timeout = 0");
    const rows = db
      .query("SELECT conversation_id, title, preview FROM conversation_summaries")
      .all() as Array<{ conversation_id?: string; title?: string | null; preview?: string | null }>;
    for (const r of rows) {
      const cid = (r.conversation_id ?? "").trim();
      if (!cid) continue;
      const name = (r.title ?? "").trim() || (r.preview ?? "").trim();
      if (name) out.set(cid, name);
    }
  } catch {
    // locked / missing / schema drift — leave the map empty
  } finally {
    db?.close();
  }
  return out;
}

/** The latest `/rename` title the user set for `conversationId`, or null. Reads
 *  agy's global history.jsonl under `antigravityHome`. Never throws. */
export async function resolveAntigravityRename(
  conversationId: string,
  antigravityHome: string,
): Promise<string | null> {
  const raw = await readOrNull(join(antigravityHome, "history.jsonl"));
  if (raw === null) return null;
  return parseAntigravityRenames(raw).get(conversationId) ?? null;
}

export async function resolveAntigravityTranscriptTitle(transcriptPath: string): Promise<string | null> {
  const raw = await readOrNull(transcriptPath);
  if (raw === null) return null;
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    let obj: any;
    try { obj = JSON.parse(t); } catch { continue; }
    if (obj?.type === "USER_INPUT") {
      const title = extractAntigravityTitle(obj.content);
      if (title) return title;
    }
  }
  return null;
}

/**
 * agy's best available conversation name, in the same precedence order claude
 * uses (manual rename > the agent's own title > first message):
 *   1. `/rename` from history.jsonl — manual intent, captured live.
 *   2. agy's own name from conversation_summaries.db — its manual `title` or
 *      generated `preview` (the lagging upgrade path).
 *   3. first user message from the transcript — until agy names it.
 * Resolving all three here (not only in the watcher) keeps a Stop/PreInvocation
 * re-derive from clobbering a higher source back down, and makes the name
 * survive resume. Only (3) is a `first-message` — the other two are real names,
 * so a generated title is never bought for them.
 */
export async function resolveAntigravityTitle(
  conversationId: string,
  antigravityHome: string,
  transcriptPath?: string,
): Promise<ResolvedTitle | null> {
  const rename = await resolveAntigravityRename(conversationId, antigravityHome);
  if (rename) return generated(rename);
  const summary = readAntigravitySummaries(antigravityHome).get(conversationId);
  if (summary) return generated(summary);
  if (!transcriptPath) return null;
  const first = await resolveAntigravityTranscriptTitle(transcriptPath);
  return first ? firstMessage(first) : null;
}
