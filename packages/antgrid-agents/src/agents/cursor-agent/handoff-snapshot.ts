import { createHash } from "node:crypto";
import { lstat, readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { runDbSerializer } from "../handoff/db-serialize";
import { withReadSnapshot } from "../handoff/sqlite-read";
import {
  SAFE_NATIVE_ID,
  refusesRealStoreUnderTest,
  type HandoffSnapshot,
  type HandoffSnapshotFn,
  type HandoffSnapshotOpts,
} from "../handoff/types";
import { readStoreMeta, type CursorSerializerArgs } from "./store-walk";

function configDir(opts: HandoffSnapshotOpts): string {
  if (opts.cursorConfigDir) return opts.cursorConfigDir;
  if (process.env.CURSOR_CONFIG_DIR) return process.env.CURSOR_CONFIG_DIR;
  return process.env.XDG_CONFIG_HOME ? join(process.env.XDG_CONFIG_HOME, "cursor") : join(homedir(), ".cursor");
}

const md5 = (value: string) => createHash("md5").update(value).digest("hex");

async function isRegularFile(path: string): Promise<boolean> {
  try {
    return (await lstat(path)).isFile();
  } catch {
    return false;
  }
}

/** Cursor files a chat under md5 of the cwd it saw; the launch cwd is tried
 * first, then the project path, then any directory holding this chat id (the
 * cwd can differ in case or form from what Cursor hashed). */
async function candidateDirs(cfg: string, chatId: string, opts: HandoffSnapshotOpts): Promise<string[]> {
  const chats = join(cfg, "chats");
  const dirs = [md5(resolve(opts.sourceCwd)), md5(resolve(opts.projectPath))].map((hash) => join(chats, hash, chatId));
  try {
    for (const entry of await readdir(chats, { withFileTypes: true })) {
      if (entry.isDirectory()) dirs.push(join(chats, entry.name, chatId));
    }
  } catch {
    // No chats directory: the explicit candidates above are all there is.
  }
  return [...new Set(dirs)];
}

/** Accepts a store only when its own record names this chat, so a stale or
 * unrelated directory that happens to share the id is never snapshotted. */
async function locateStore(cfg: string, chatId: string, opts: HandoffSnapshotOpts): Promise<string | undefined> {
  for (const dir of await candidateDirs(cfg, chatId, opts)) {
    const store = join(dir, "store.db");
    if (!(await isRegularFile(store))) continue;
    try {
      if (withReadSnapshot(store, readStoreMeta)?.agentId === chatId) return dir;
    } catch {
      // An unreadable candidate does not rule out another directory holding the chat.
    }
  }
  return undefined;
}

async function readChatMeta(dir: string): Promise<Pick<CursorSerializerArgs, "cwd" | "title" | "updatedAtMs">> {
  try {
    const meta = JSON.parse(await readFile(join(dir, "meta.json"), "utf8")) as Record<string, unknown>;
    return {
      ...(typeof meta.cwd === "string" ? { cwd: meta.cwd } : {}),
      ...(typeof meta.title === "string" ? { title: meta.title } : {}),
      ...(typeof meta.updatedAtMs === "number" ? { updatedAtMs: meta.updatedAtMs } : {}),
    };
  } catch {
    return {};
  }
}

export const cursorSnapshot: HandoffSnapshotFn = async (opts): Promise<HandoffSnapshot | undefined> => {
  const chatId = opts.agentSessionId;
  if (refusesRealStoreUnderTest(opts.cursorConfigDir) || !chatId || !SAFE_NATIVE_ID.test(chatId)) return undefined;
  const dir = await locateStore(configDir(opts), chatId, opts);
  if (!dir) return undefined;
  const result = await runDbSerializer({
    serializer: "cursor",
    dbPath: join(dir, "store.db"),
    outDir: opts.outDir,
    args: { chatId, ...(await readChatMeta(dir)) } satisfies CursorSerializerArgs,
    signal: opts.signal,
  });
  if (!result.files.length) return undefined;
  return {
    agent: "cursor-agent",
    agentSessionId: chatId,
    method: "db-serialize",
    primary: "cursor-chat.jsonl",
    files: result.files,
    references: result.references,
    redactions: result.redactions,
    warnings: result.warnings,
  };
};
