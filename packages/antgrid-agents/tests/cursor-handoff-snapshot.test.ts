import { afterEach, beforeEach, expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { cursorAgentFork } from "../src/agents/cursor-agent/fork";
import { cursorSnapshot } from "../src/agents/cursor-agent/handoff-snapshot";
import { walkRootBlob } from "../src/agents/cursor-agent/store-walk";
import { safeJoin, type HandoffSnapshotOpts } from "../src/agents/handoff";
import { withEnv } from "./fixtures/with-env";

let root: string;
beforeEach(() => { root = mkdtempSync(join(tmpdir(), "cursor-handoff-")); });
afterEach(() => rmSync(root, { recursive: true, force: true }));

const CHAT = "11111111-2222-3333-4444-555555555555";

// A 20-line protobuf encoder: just enough wire format to build a root blob.
function varint(n: number): number[] {
  const out: number[] = [];
  while (n >= 0x80) { out.push((n % 0x80) | 0x80); n = Math.floor(n / 0x80); }
  out.push(n);
  return out;
}
const tag = (field: number, wire: number) => varint(field * 8 + wire);
const lengthDelimited = (field: number, bytes: Uint8Array | number[]) => [...tag(field, 2), ...varint(bytes.length), ...bytes];
const varintField = (field: number, value: number) => [...tag(field, 0), ...varint(value)];
const sha = (data: Uint8Array | string) => createHash("sha256").update(data).digest();

interface Chat { dir: string; db: Database; blob(data: Uint8Array | string): Buffer }

function createChat(cfg: string, cwd: string): Chat {
  const dir = join(cfg, "chats", createHash("md5").update(resolve(cwd)).digest("hex"), CHAT);
  mkdirSync(dir, { recursive: true });
  const db = new Database(join(dir, "store.db"));
  db.run("PRAGMA journal_mode = WAL");
  db.run("CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB)");
  db.run("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)");
  writeFileSync(join(dir, "meta.json"), JSON.stringify({ schemaVersion: 1, updatedAtMs: 99, title: "A chat", cwd }));
  const chat: Chat = {
    dir,
    db,
    blob(data) {
      const bytes = typeof data === "string" ? Buffer.from(data) : Buffer.from(data);
      const digest = sha(bytes);
      db.run("INSERT OR REPLACE INTO blobs VALUES (?, ?)", [digest.toString("hex"), bytes]);
      return digest;
    },
  };
  return chat;
}

function setMeta(chat: Chat, root: Buffer, extra: Record<string, unknown> = {}): void {
  const meta = { agentId: CHAT, latestRootBlobId: root.toString("hex"), name: "Chat", createdAt: 5, mode: "default", lastUsedModel: "m1", blobEncryptionKey: "SECRET-KEY", ...extra };
  chat.db.run("INSERT OR REPLACE INTO meta VALUES ('0', ?)", [Buffer.from(JSON.stringify(meta)).toString("hex")]);
}

function opts(outDir: string, cfg: string, overrides: Partial<HandoffSnapshotOpts> = {}): HandoffSnapshotOpts {
  return { maxMsgs: 10, projectPath: "/proj", outDir, sourceCwd: "/work", signal: new AbortController().signal, cursorConfigDir: cfg, agentSessionId: CHAT, ...overrides };
}

test("walks the root blob's field-1 ids in order, ignoring other lengths and fields", () => {
  const a = sha("a");
  const b = sha("b");
  const root = Buffer.from([
    ...lengthDelimited(1, a),
    ...varintField(37, 300),
    ...lengthDelimited(1, [1, 2, 3]),
    ...lengthDelimited(1, b),
  ]);
  expect(walkRootBlob(root).messageIds).toEqual([a.toString("hex"), b.toString("hex")]);
  expect(() => walkRootBlob(Buffer.from([0x0a, 0x7f]))).toThrow();
});

test("serializes header, archive and message blobs in order and never emits blobEncryptionKey", async () => {
  const cfg = join(root, "cfg");
  const chat = createChat(cfg, "/work");
  const archived = chat.blob(JSON.stringify({ role: "user", content: "old question" }));
  const summaryMsg = chat.blob(JSON.stringify({ role: "user", content: "summary", providerOptions: { cursor: { isSummary: true } } }));
  const m1 = chat.blob(JSON.stringify({ role: "user", content: [{ type: "text", text: "hello \"world\"" }] }));
  const m2 = chat.blob(JSON.stringify({ role: "assistant", content: [{ type: "text", text: "hi" }] }));
  const multiline = chat.blob('{"role":"user",\n"content":"split"}');
  const notJson = chat.blob(Buffer.from([0x0a, 0x03, 0x61, 0x62, 0x63]));
  const archive = [
    ...lengthDelimited(1, archived),
    ...lengthDelimited(2, Buffer.from("the summary")),
    ...varintField(3, 4),
    ...lengthDelimited(4, summaryMsg),
  ];
  const rootBlob = chat.blob(Buffer.from([
    ...lengthDelimited(1, m1),
    ...lengthDelimited(1, multiline),
    ...lengthDelimited(1, m2),
    ...lengthDelimited(1, notJson),
    ...lengthDelimited(13, archive),
    ...varintField(37, 2),
  ]));
  setMeta(chat, rootBlob);
  const outDir = join(root, "out");
  mkdirSync(outDir);

  const snapshot = await cursorSnapshot(opts(outDir, cfg));
  chat.db.close();

  expect(snapshot?.method).toBe("db-serialize");
  expect(snapshot?.primary).toBe("cursor-chat.jsonl");
  expect(snapshot?.files.map((f) => f.name)).toEqual(["cursor-chat.jsonl"]);
  for (const file of snapshot!.files) expect(() => safeJoin(outDir, file.name)).not.toThrow();
  expect(readdirSync(outDir)).toEqual(["cursor-chat.jsonl"]);

  const text = readFileSync(join(outDir, "cursor-chat.jsonl"), "utf8");
  expect(text).not.toContain("SECRET-KEY");
  expect(text).not.toContain("blobEncryptionKey");
  expect(snapshot?.redactions.join("\n")).toContain("blobEncryptionKey");
  const lines = text.trimEnd().split("\n").map((line) => JSON.parse(line));
  expect(lines[0]).toEqual({ type: "header", chatId: CHAT, name: "Chat", mode: "default", createdAt: 5, lastUsedModel: "m1", latestRootBlobId: rootBlob.toString("hex"), cwd: "/work", title: "A chat", updatedAtMs: 99 });
  expect(lines[1]).toMatchObject({ type: "summary_archive", archiveIndex: 0, summary: "the summary", windowTail: 4, summaryMessageBlobId: summaryMsg.toString("hex") });
  expect(lines[2]).toMatchObject({ type: "message", archived: true, archiveIndex: 0, blobId: archived.toString("hex"), message: { content: "old question" } });
  expect(lines.slice(3).map((l) => l.blobId)).toEqual([m1.toString("hex"), m2.toString("hex")]);
  expect(lines[3].message.content[0].text).toBe("hello \"world\"");
  // The message blob is spliced as stored, not re-serialized.
  expect(text).toContain(`"message":{"role":"user","content":[{"type":"text","text":"hello \\"world\\""}]}`);
  expect(snapshot?.warnings.join("\n")).toContain("Skipped 2 message blobs");
});

test("sees WAL-only rows and never writes the chat directory", async () => {
  const cfg = join(root, "cfg");
  const chat = createChat(cfg, "/work");
  chat.db.run("PRAGMA wal_autocheckpoint = 0");
  const m1 = chat.blob(JSON.stringify({ role: "user", content: "wal only" }));
  setMeta(chat, chat.blob(Buffer.from(lengthDelimited(1, m1))));
  const before = { db: readFileSync(join(chat.dir, "store.db")), wal: readFileSync(join(chat.dir, "store.db-wal")) };
  const outDir = join(root, "out");
  mkdirSync(outDir);

  const snapshot = await cursorSnapshot(opts(outDir, cfg));

  expect(snapshot?.files).toHaveLength(1);
  expect(readFileSync(join(outDir, "cursor-chat.jsonl"), "utf8")).toContain("wal only");
  expect(readFileSync(join(chat.dir, "store.db")).equals(before.db)).toBe(true);
  expect(readFileSync(join(chat.dir, "store.db-wal")).equals(before.wal)).toBe(true);
  chat.db.close();
});

test("falls back to a glob when the cwd hash differs", async () => {
  const cfg = join(root, "cfg");
  const chat = createChat(cfg, "/somewhere-else");
  const m1 = chat.blob(JSON.stringify({ role: "user", content: "x" }));
  setMeta(chat, chat.blob(Buffer.from(lengthDelimited(1, m1))));
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await cursorSnapshot(opts(outDir, cfg))).toBeDefined();
  chat.db.close();
});

test("rejects a store whose meta agentId differs", async () => {
  const cfg = join(root, "cfg");
  const chat = createChat(cfg, "/work");
  const m1 = chat.blob(JSON.stringify({ role: "user", content: "x" }));
  setMeta(chat, chat.blob(Buffer.from(lengthDelimited(1, m1))), { agentId: "99999999-2222-3333-4444-555555555555" });
  chat.db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await cursorSnapshot(opts(outDir, cfg))).toBeUndefined();
  expect(readdirSync(outDir)).toEqual([]);
});

test("returns undefined for an unsafe id, a missing chat, or the real store under test", async () => {
  const cfg = join(root, "cfg");
  const outDir = join(root, "out");
  mkdirSync(outDir);
  expect(await cursorSnapshot(opts(outDir, cfg, { agentSessionId: "../escape" }))).toBeUndefined();
  expect(await cursorSnapshot(opts(outDir, cfg))).toBeUndefined();
  const chat = createChat(cfg, "/work");
  const m1 = chat.blob(JSON.stringify({ role: "user", content: "x" }));
  setMeta(chat, chat.blob(Buffer.from(lengthDelimited(1, m1))));
  expect(await withEnv("CURSOR_CONFIG_DIR", cfg, () => cursorSnapshot(opts(outDir, cfg, { cursorConfigDir: undefined })))).toBeUndefined();
  expect(await cursorSnapshot(opts(outDir, cfg))).toBeDefined();
  chat.db.close();
});

test("a root blob that is not protobuf is unreadable", async () => {
  const cfg = join(root, "cfg");
  const chat = createChat(cfg, "/work");
  setMeta(chat, chat.blob(Buffer.from([0x0a, 0x7f])));
  chat.db.close();
  const outDir = join(root, "out");
  mkdirSync(outDir);
  await expect(cursorSnapshot(opts(outDir, cfg))).rejects.toMatchObject({ code: "UNREADABLE" });
});

test("cursorAgentFork stays a terminal-transcript fork with a snapshot", () => {
  expect(cursorAgentFork.kind).toBe("terminal-transcript");
  expect(cursorAgentFork.snapshot).toBe(cursorSnapshot);
});
