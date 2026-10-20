import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { safeJoin } from "../src/agents/handoff";
import { kimiFork } from "../src/agents/kimi/fork";
import { snapshotKimi } from "../src/agents/kimi/handoff-snapshot";

const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const temp = (prefix: string) => { const dir = mkdtempSync(join(tmpdir(), prefix)); dirs.push(dir); return dir; };

const ID = "session_11111111-2222-3333-4444-555555555555";
const WIRE = '{"type":"metadata","protocol_version":"1.5"}\n{"type":"user","text":"hello"}\n';

function store(options: { index?: boolean; sessionDir?: string } = {}) {
  const home = temp("antgrid-kimi-home-");
  const sessionDir = join(home, "sessions", "wd_repo_abc123", ID);
  mkdirSync(join(sessionDir, "agents", "main"), { recursive: true });
  writeFileSync(join(sessionDir, "agents", "main", "wire.jsonl"), `${WIRE}{"type":"torn`);
  writeFileSync(join(sessionDir, "state.json"), '{"title":"A title"}');
  if (options.index !== false) {
    writeFileSync(join(home, "session_index.jsonl"), `${JSON.stringify({ sessionId: ID, sessionDir: (options.sessionDir ?? sessionDir).replace(/\\/g, "/"), workDir: "/repo" })}\n`);
  }
  return { home, sessionDir };
}

const run = (home: string, extra: Record<string, unknown> = {}) => snapshotKimi({
  maxMsgs: 10, projectPath: "/repo", sourceCwd: "/repo", agentSessionId: ID,
  outDir: temp("antgrid-kimi-out-"), signal: new AbortController().signal, kimiHome: home, ...extra,
});

test("Kimi snapshot copies the main wire at the last newline and the state sidecar", async () => {
  const { home, sessionDir } = store();
  const outDir = temp("antgrid-kimi-out-");
  const snapshot = await run(home, { outDir });
  expect(snapshot?.primary).toBe("kimi-wire.jsonl");
  expect(snapshot?.method).toBe("copy");
  expect(readFileSync(join(outDir, "kimi-wire.jsonl"), "utf8")).toBe(WIRE);
  expect(readFileSync(join(outDir, "kimi-state.json"), "utf8")).toBe('{"title":"A title"}');
  expect(snapshot?.files.map((file) => file.name)).toEqual(["kimi-wire.jsonl", "kimi-state.json"]);
  expect(snapshot?.references).toEqual([]);
  for (const file of snapshot!.files) expect(() => safeJoin(outDir, file.name)).not.toThrow();
  void sessionDir;
});

test("Kimi snapshot lists subagent logs and tool results as references without copying them", async () => {
  const { home, sessionDir } = store();
  mkdirSync(join(sessionDir, "agents", "sub1"), { recursive: true });
  mkdirSync(join(sessionDir, "agents", "main", "tool-results"), { recursive: true });
  const snapshot = await run(home);
  expect(snapshot?.references.map((reference) => reference.path).sort()).toEqual([
    join(sessionDir, "agents", "main", "tool-results"),
    join(sessionDir, "agents", "sub1"),
  ].sort());
  expect(snapshot?.files).toHaveLength(2);
});

test("Kimi snapshot falls back to the sessions glob when the index has no record", async () => {
  const { home } = store({ index: false });
  expect((await run(home))?.primary).toBe("kimi-wire.jsonl");
});

test("Kimi snapshot treats a later deleted record as gone, even though the files remain", async () => {
  const { home, sessionDir } = store();
  writeFileSync(join(home, "session_index.jsonl"), [
    JSON.stringify({ sessionId: ID, sessionDir: sessionDir.replace(/\\/g, "/") }),
    JSON.stringify({ sessionId: ID, deleted: true }),
  ].join("\n") + "\n", { flag: "w" });
  expect(await run(home)).toBeUndefined();
});

test("Kimi snapshot refuses an index sessionDir outside the home and globs instead", async () => {
  const outside = temp("antgrid-kimi-outside-");
  mkdirSync(join(outside, "agents", "main"), { recursive: true });
  writeFileSync(join(outside, "agents", "main", "wire.jsonl"), '{"type":"metadata","from":"outside"}\n');
  const { home } = store({ sessionDir: outside });
  const outDir = temp("antgrid-kimi-out-");
  await run(home, { outDir });
  expect(readFileSync(join(outDir, "kimi-wire.jsonl"), "utf8")).toBe(WIRE);
});

test("Kimi snapshot finds nothing when the index points outside the home and no glob hit exists", async () => {
  const outside = temp("antgrid-kimi-outside-");
  mkdirSync(join(outside, "agents", "main"), { recursive: true });
  writeFileSync(join(outside, "agents", "main", "wire.jsonl"), "{}\n");
  const home = temp("antgrid-kimi-home-");
  writeFileSync(join(home, "session_index.jsonl"), `${JSON.stringify({ sessionId: ID, sessionDir: outside.replace(/\\/g, "/") })}\n`);
  expect(await run(home)).toBeUndefined();
});

test("Kimi snapshot refuses unsafe ids and returns undefined for a missing store", async () => {
  const { home } = store();
  expect(await run(home, { agentSessionId: "../escape" })).toBeUndefined();
  expect(await run(home, { agentSessionId: undefined })).toBeUndefined();
  expect(await run(temp("antgrid-kimi-empty-"))).toBeUndefined();
});

test("Kimi snapshot refuses a symlinked wire", async () => {
  const { home, sessionDir } = store();
  const real = join(sessionDir, "agents", "main", "wire.jsonl");
  const target = join(temp("antgrid-kimi-target-"), "wire.jsonl");
  writeFileSync(target, WIRE);
  rmSync(real);
  try { symlinkSync(target, real); } catch { return; }
  expect(await run(home)).toBeUndefined();
});

test("Kimi snapshot is refused under the test runner without a seam", async () => {
  expect(await snapshotKimi({
    maxMsgs: 10, projectPath: "/repo", sourceCwd: "/repo", agentSessionId: ID,
    outDir: temp("antgrid-kimi-out-"), signal: new AbortController().signal,
  })).toBeUndefined();
});

test("Kimi fork keeps its native fork shape and carries the snapshot", () => {
  expect(kimiFork.kind).toBe("native-fork");
  expect(kimiFork.nativeForkKeepsWorkspace).toBe(true);
  expect(kimiFork.snapshot).toBe(snapshotKimi);
});
