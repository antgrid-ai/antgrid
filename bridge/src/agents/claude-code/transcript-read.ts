import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

// Claude Code persists each session's transcript as a JSONL file at
// ~/.claude/projects/<cwd-slug>/<session-id>.jsonl. The Agent SDK exposes no
// transcript-read API (probe-verified), so the driver reads this file directly
// to backfill history on a cold resume — the on-disk entries are already in
// claudeResumeReplay's expected shape ({ type, message, uuid }). See
// chat-backend.ts's getTranscriptSnapshot.

// The slug replaces every non-alphanumeric char in the absolute cwd with "-",
// with NO collapsing of consecutive dashes ("C:\" -> "C--"). Verified against
// the real binary's on-disk layout — keep in lockstep if Claude Code changes it.
export function claudeProjectSlug(cwd: string): string {
  return cwd.replace(/[^a-zA-Z0-9]/g, "-");
}

// Bound on replayed entries, mirroring the driver's in-memory HISTORY_MAX_ENTRIES
// so a long-lived session's backfill can't grow unbounded. Keeps the most recent.
const MAX_ENTRIES = 500;

function projectsRoot(): string {
  // homedir() resolves to USERPROFILE on Windows, matching buildClaudeEnv's
  // HOME override — so this points at the same ~/.claude the SDK writes to.
  return join(homedir(), ".claude", "projects");
}

async function tryRead(path: string): Promise<string | null> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return null;
  }
}

// Claude Code records a slash command's echo and its output as ordinary
// string-content user entries — `<command-name>/model</command-name>…` and
// `<local-command-stdout>…`, neither of which carries isMeta (only the
// `<local-command-caveat>` line does). They are CLI plumbing, not the user
// talking, and the live/in-memory path never records them, so drop them here to
// keep disk backfill at parity. Matching requires the content be ENTIRELY
// wrapper elements, so a prompt that merely quotes one survives.
const LOCAL_COMMAND_TAG = "command-name|command-message|command-args|command-contents|local-command-stdout|local-command-stderr";
// Strip-and-check rather than one anchored `(?:<tag>…</tag>)+$` match: repeating
// a group around a lazy inner quantifier backtracks catastrophically on a long
// entry that opens a wrapper but never cleanly closes it.
const LOCAL_COMMAND_ELEMENT = new RegExp(`<(?:${LOCAL_COMMAND_TAG})>[\\s\\S]*?</(?:${LOCAL_COMMAND_TAG})>`, "g");

function isLocalCommandNoise(entry: any): boolean {
  const c = entry?.message?.content;
  if (typeof c !== "string") return false;
  const s = c.trim();
  if (!s.startsWith("<")) return false; // ordinary prompt — cheap reject
  return s.replace(LOCAL_COMMAND_ELEMENT, "").trim() === "";
}

function parseTranscript(raw: string): any[] {
  const out: any[] = [];
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let entry: any;
    try {
      entry = JSON.parse(trimmed);
    } catch {
      continue; // partial/corrupt line — skip, don't fail the whole read
    }
    // Subagent (Task) sidechain turns and injected meta turns are not part of
    // the user-visible main thread — the live/in-memory path never records
    // them, so drop them here to keep disk backfill at parity.
    if (entry?.isSidechain === true || entry?.isMeta === true) continue;
    if (entry?.type !== "user" && entry?.type !== "assistant") continue;
    if (isLocalCommandNoise(entry)) continue;
    out.push(entry);
  }
  // Cap AFTER filtering so the budget counts real messages, not queue-operation
  // / attachment noise.
  if (out.length > MAX_ENTRIES) out.splice(0, out.length - MAX_ENTRIES);
  return out;
}

// Returns the session's completed-history entries (claudeResumeReplay-shaped),
// or [] if the transcript can't be located/read. `root` is injectable for tests.
export async function readClaudeTranscript(
  cwd: string,
  sessionId: string,
  root: string = projectsRoot(),
): Promise<any[]> {
  const primary = join(root, claudeProjectSlug(cwd), `${sessionId}.jsonl`);
  let raw = await tryRead(primary);
  if (raw == null) {
    // Fallback: the session id is a globally-unique UUID, so scan project dirs
    // for it — covers a cwd that differs from the one Claude recorded
    // (symlink/case) or a future slug-algorithm drift.
    let dirs: string[];
    try {
      dirs = await readdir(root);
    } catch {
      return [];
    }
    for (const dir of dirs) {
      raw = await tryRead(join(root, dir, `${sessionId}.jsonl`));
      if (raw != null) break;
    }
  }
  if (raw == null) return [];
  return parseTranscript(raw);
}
