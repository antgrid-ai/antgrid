import { Database } from "bun:sqlite";
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { HandoffSnapshotError, safeJoin, type HandoffSnapshotOpts } from "../src/agents/handoff";
import { codexFork } from "../src/agents/codex/fork";
import { withEnv } from "./fixtures/with-env";

const T = "019aaaaa-0000-7000-8000-000000000001";
const BASE = "019aaaaa-0000-7000-8000-000000000002";
const OTHER = "019aaaaa-0000-7000-8000-000000000003";
const REV = "019bbbbb-0000-7000-8000-00000000000a";

let root: string;
let home: string;
let out: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "codex-handoff-"));
  home = join(root, "codex");
  out = join(root, "out");
  mkdirSync(home);
  mkdirSync(out);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const line = (type: string, payload: Record<string, unknown>) => `${JSON.stringify({ timestamp: "t", type, payload })}\n`;
const meta = (id: string, historyBase?: Record<string, unknown>) =>
  line("session_meta", { id, history_mode: "paginated", ...(historyBase ? { history_base: historyBase } : {}) });
const user = (text: string) =>
  line("event_msg", { type: "item_completed", item: { type: "UserMessage", content: [{ type: "text", text }] } });

function put(rel: string, content: string, zst = false): string {
  const path = join(home, rel);
  mkdirSync(dirname(path), { recursive: true });
  if (zst) {
    writeFileSync(`${path}.zst`, Bun.zstdCompressSync(Buffer.from(content)));
    return path;
  }
  writeFileSync(path, content);
  return path;
}

function stateDb(rows: Array<{ id: string; rollout_path: string }>): void {
  const db = new Database(join(home, "state_5.sqlite"));
  db.run("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT)");
  for (const row of rows) db.query("INSERT INTO threads (id, rollout_path) VALUES (?, ?)").run(row.id, row.rollout_path);
  db.close();
}

function opts(over: Partial<HandoffSnapshotOpts> = {}): HandoffSnapshotOpts {
  return {
    projectPath: root,
    maxMsgs: 10,
    agentSessionId: T,
    codexHome: home,
    outDir: out,
    sourceCwd: root,
    signal: new AbortController().signal,
    ...over,
  };
}

const read = (name: string) => readFileSync(join(out, name), "utf8");

test("locates a zst-only rollout from the state DB path", async () => {
  const body = meta(T) + user("hello");
  // Not a name the directory scan accepts, so only the recorded path can find it.
  const plain = join(home, "sessions", "2026", "01", "01", `saved-${T}.jsonl`);
  put(`sessions/2026/01/01/saved-${T}.jsonl`, body, true);
  stateDb([{ id: T, rollout_path: plain }]);

  const snapshot = await codexFork.snapshot(opts());

  expect(snapshot).toMatchObject({ agent: "codex", agentSessionId: T, method: "decompress", primary: "codex-rollout-01.jsonl" });
  expect(read("codex-rollout-01.jsonl")).toBe(body);
});

test("finds an archived thread with no state database", async () => {
  const body = meta(T) + user("old");
  put(`archived_sessions/rollout-2025-01-01T00-00-00-${T}.jsonl`, body);

  const snapshot = await codexFork.snapshot(opts());

  expect(snapshot?.method).toBe("copy");
  expect(read("codex-rollout-01.jsonl")).toBe(body);
});

test("drops a torn final line of a live rollout", async () => {
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, `${meta(T)}${user("a")}{"torn":`);

  await codexFork.snapshot(opts());

  expect(read("codex-rollout-01.jsonl")).toBe(meta(T) + user("a"));
});

test("walks history_base by rollout id, truncating each base at end_byte_offset, root segment first", async () => {
  const kept = meta(BASE) + user("original task");
  const base = kept + user("after the fork point");
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${BASE}.jsonl`, base, true);
  const leaf = meta(T, { thread_id: BASE, end_ordinal_exclusive: 2, end_byte_offset: Buffer.byteLength(kept) }) + user("follow-up");
  put(`sessions/2026/01/02/rollout-2026-01-02T00-00-00-${T}.jsonl`, leaf, true);

  const snapshot = await codexFork.snapshot(opts());

  expect(snapshot?.files.map((f) => [f.name, f.role])).toEqual([
    ["codex-rollout-01.jsonl", "segment"],
    ["codex-rollout-02.jsonl", "transcript"],
  ]);
  expect(snapshot?.primary).toBe("codex-rollout-02.jsonl");
  expect(read("codex-rollout-01.jsonl")).toBe(kept);
  expect(read("codex-rollout-02.jsonl")).toBe(leaf);
  expect(snapshot?.files[0]?.sourceRange).toEqual({ start: 0, end: Buffer.byteLength(kept) });
});

test("a rollback revision resolves to the same thread's original file", async () => {
  const original = meta(T) + user("first") + user("second");
  const kept = meta(T) + user("first");
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, original);
  const revision = meta(T, { thread_id: T, end_ordinal_exclusive: 2, end_byte_offset: Buffer.byteLength(kept) }) + user("redo");
  const revisionPath = put(`sessions/2026/01/02/rollout-2026-01-02T00-00-00-${T}_${REV}.jsonl`, revision);
  stateDb([{ id: T, rollout_path: revisionPath }]);

  const snapshot = await codexFork.snapshot(opts());

  expect(snapshot?.files).toHaveLength(2);
  expect(read("codex-rollout-01.jsonl")).toBe(kept);
  expect(read("codex-rollout-02.jsonl")).toBe(revision);
});

test("a cyclic history_base is refused, not looped", async () => {
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, meta(T, { thread_id: BASE, end_byte_offset: 10 }) + user("x"));
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${BASE}.jsonl`, meta(BASE, { thread_id: T, end_byte_offset: 10 }) + user("y"));

  const error = await codexFork.snapshot(opts()).catch((e) => e);

  expect(error).toBeInstanceOf(HandoffSnapshotError);
  expect(error.code).toBe("UNREADABLE");
  expect(error.message).toContain("leads back into its own lineage");
});

test("an unsafe history_base.thread_id is refused", async () => {
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, meta(T, { thread_id: "../../etc", end_byte_offset: 10 }) + user("x"));

  const error = await codexFork.snapshot(opts()).catch((e) => e);

  expect(error).toBeInstanceOf(HandoffSnapshotError);
  expect(readdirSync(out)).toEqual([]);
});

test("a missing history base refuses rather than copying a headless thread", async () => {
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, meta(T, { thread_id: OTHER, end_byte_offset: 10 }) + user("x"));

  const error = await codexFork.snapshot(opts()).catch((e) => e);

  expect(error).toBeInstanceOf(HandoffSnapshotError);
});

test("a hook transcriptPath outside the store is ignored", async () => {
  const outside = join(root, "elsewhere");
  mkdirSync(outside);
  const planted = join(outside, `rollout-2026-01-01T00-00-00-${T}.jsonl`);
  writeFileSync(planted, meta(T) + user("planted"));

  expect(await codexFork.snapshot(opts({ transcriptPath: planted }))).toBeUndefined();

  const real = meta(T) + user("real");
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, real);
  await codexFork.snapshot(opts({ transcriptPath: planted }));
  expect(read("codex-rollout-01.jsonl")).toBe(real);
});

test("a hook transcriptPath inside the store is honoured", async () => {
  const hinted = put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, meta(T) + user("hinted"));
  // Newer, so a scan alone would pick it over the hinted file.
  put(`sessions/2026/02/01/rollout-2026-02-01T00-00-00-${T}.jsonl`, meta(T) + user("newer"));

  await codexFork.snapshot(opts({ transcriptPath: hinted }));

  expect(read("codex-rollout-01.jsonl")).toContain("hinted");
});

test("returns undefined for an unknown thread and for an unsafe id", async () => {
  expect(await codexFork.snapshot(opts())).toBeUndefined();
  expect(await codexFork.snapshot(opts({ agentSessionId: "../x" }))).toBeUndefined();
  expect(await codexFork.snapshot(opts({ agentSessionId: undefined }))).toBeUndefined();
});

test("every emitted file name passes safeJoin", async () => {
  const kept = meta(BASE) + user("a");
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${BASE}.jsonl`, kept);
  put(`sessions/2026/01/02/rollout-2026-01-02T00-00-00-${T}.jsonl`, meta(T, { thread_id: BASE, end_byte_offset: Buffer.byteLength(kept) }) + user("b"));

  const snapshot = await codexFork.snapshot(opts());

  for (const file of snapshot!.files) expect(() => safeJoin(out, file.name)).not.toThrow();
});

test("refuses to read a real store under the test runner when no home is given", async () => {
  put(`sessions/2026/01/01/rollout-2026-01-01T00-00-00-${T}.jsonl`, meta(T) + user("real"));
  expect(await withEnv("CODEX_HOME", home, () => codexFork.snapshot(opts({ codexHome: undefined })))).toBeUndefined();
  expect(await codexFork.snapshot(opts())).toBeDefined();
});
