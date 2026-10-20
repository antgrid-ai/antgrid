import { afterEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { safeJoin } from "../src/agents/handoff";
import { vibeFork } from "../src/agents/mistral-vibe/fork";
import { snapshotVibe } from "../src/agents/mistral-vibe/handoff-snapshot";
import { withEnv } from "./fixtures/with-env";

const dirs: string[] = [];
afterEach(() => { for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true }); });
const temp = (prefix: string) => { const dir = mkdtempSync(join(tmpdir(), prefix)); dirs.push(dir); return dir; };

const ID = "0123456789abcdef0123-abcdefabcdef";
const MESSAGES = '{"role":"user","content":"hi"}\n{"role":"assistant","content":"hello"}\n';

function session(saveDir: string, id: string, cwd: string, stamp = "20260101_120000") {
  const dir = join(saveDir, `session_${stamp}_${id.slice(0, 8)}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "messages.jsonl"), `${MESSAGES}{"role":"us`);
  writeFileSync(join(dir, "meta.json"), JSON.stringify({
    session_id: id, start_time: "2026-01-01T12:00:00Z", end_time: null, git_branch: "main", username: "someone",
    environment: { working_directory: cwd, os: "win32" }, origin_directory: cwd, total_messages: 2,
    config: { api_key: "SECRET-CONFIG" }, system_prompt: "SECRET-PROMPT", tools_available: ["bash"],
  }, null, 2));
  return dir;
}

function store() {
  const home = temp("antgrid-vibe-home-");
  const saveDir = join(home, "logs", "session");
  mkdirSync(saveDir, { recursive: true });
  return { home, saveDir };
}

const run = (home: string, extra: Record<string, unknown> = {}) => snapshotVibe({
  maxMsgs: 10, projectPath: "/repo", sourceCwd: "/repo", agentSessionId: ID,
  outDir: temp("antgrid-vibe-out-"), signal: new AbortController().signal, vibeHome: home, ...extra,
});

test("Vibe snapshot finds the session by id suffix and copies whole lines", async () => {
  const { home, saveDir } = store();
  session(saveDir, "ffffffff-other", "/other");
  session(saveDir, ID, "/repo");
  const outDir = temp("antgrid-vibe-out-");
  const snapshot = await run(home, { outDir });
  expect(snapshot?.primary).toBe("vibe-messages.jsonl");
  expect(snapshot?.agentSessionId).toBe(ID);
  expect(readFileSync(join(outDir, "vibe-messages.jsonl"), "utf8")).toBe(MESSAGES);
  for (const file of snapshot!.files) expect(() => safeJoin(outDir, file.name)).not.toThrow();
});

test("Vibe snapshot meta allowlist drops the config dump", async () => {
  const { home, saveDir } = store();
  session(saveDir, ID, "/repo");
  const outDir = temp("antgrid-vibe-out-");
  const snapshot = await run(home, { outDir });
  const text = readFileSync(join(outDir, "vibe-meta.json"), "utf8");
  expect(text).not.toContain("SECRET");
  expect(JSON.parse(text)).toEqual({
    session_id: ID, start_time: "2026-01-01T12:00:00Z", end_time: null, environment: { working_directory: "/repo" },
    origin_directory: "/repo", total_messages: 2,
  });
  expect(snapshot?.redactions).toHaveLength(1);
});

test("Vibe snapshot does not take a session whose meta names another id", async () => {
  const { home, saveDir } = store();
  const dir = session(saveDir, ID, "/repo");
  writeFileSync(join(dir, "meta.json"), JSON.stringify({ session_id: "0123456789zzzzzzzzzz-other" }));
  expect(await run(home)).toBeUndefined();
});

test("Vibe snapshot lists subagents and attachments as references", async () => {
  const { home, saveDir } = store();
  const dir = session(saveDir, ID, "/repo");
  mkdirSync(join(dir, "agents", "task_x"), { recursive: true });
  mkdirSync(join(dir, "attachments"));
  const snapshot = await run(home);
  expect(snapshot?.references.map((reference) => reference.path).sort()).toEqual([join(dir, "agents"), join(dir, "attachments")].sort());
});

test("Vibe snapshot prefers a hook transcript path inside the save dir", async () => {
  const { home, saveDir } = store();
  const older = session(saveDir, ID, "/repo", "20260101_120000");
  writeFileSync(join(older, "messages.jsonl"), '{"role":"user","content":"OLDER"}\n');
  session(saveDir, ID, "/repo", "20260102_120000");
  const outDir = temp("antgrid-vibe-out-");
  const snapshot = await run(home, { outDir, transcriptPath: join(older, "messages.jsonl") });
  expect(snapshot?.primary).toBe("vibe-messages.jsonl");
  // Without the hint the id scan would take the newer directory.
  expect(readFileSync(join(outDir, "vibe-messages.jsonl"), "utf8")).toContain("OLDER");
});

test("Vibe snapshot ignores a hook transcript path outside the store", async () => {
  const { home, saveDir } = store();
  session(saveDir, ID, "/repo");
  const outside = temp("antgrid-vibe-outside-");
  writeFileSync(join(outside, "messages.jsonl"), '{"role":"user","content":"OUTSIDE"}\n');
  const outDir = temp("antgrid-vibe-out-");
  await run(home, { outDir, transcriptPath: join(outside, "messages.jsonl") });
  expect(readFileSync(join(outDir, "vibe-messages.jsonl"), "utf8")).toBe(MESSAGES);
});

test("Vibe snapshot ignores a hint that is a subagent log", async () => {
  const { home, saveDir } = store();
  const dir = session(saveDir, ID, "/repo");
  mkdirSync(join(dir, "agents", `task_${ID.slice(0, 8)}`), { recursive: true });
  writeFileSync(join(dir, "agents", `task_${ID.slice(0, 8)}`, "messages.jsonl"), '{"role":"user","content":"SUB"}\n');
  const outDir = temp("antgrid-vibe-out-");
  await run(home, { outDir, transcriptPath: join(dir, "agents", `task_${ID.slice(0, 8)}`, "messages.jsonl") });
  expect(readFileSync(join(outDir, "vibe-messages.jsonl"), "utf8")).toBe(MESSAGES);
});

test("Vibe snapshot without an id accepts only a unique working-directory match", async () => {
  const { home, saveDir } = store();
  session(saveDir, ID, "/repo");
  session(saveDir, "aaaaaaaa-bbbb", "/elsewhere");
  const unique = await run(home, { agentSessionId: undefined });
  expect(unique?.agentSessionId).toBe(ID);
  session(saveDir, "cccccccc-dddd", "/repo", "20260102_120000");
  expect(await run(home, { agentSessionId: undefined })).toBeUndefined();
});

test("Vibe snapshot refuses unsafe ids and returns undefined for a missing store", async () => {
  const { home, saveDir } = store();
  session(saveDir, ID, "/repo");
  expect(await run(home, { agentSessionId: "../x" })).toBeUndefined();
  expect(await run(temp("antgrid-vibe-empty-"))).toBeUndefined();
});

test("Vibe snapshot is refused under the test runner without a seam", async () => {
  const { home, saveDir } = store();
  session(saveDir, ID, "/repo");
  expect(await withEnv("VIBE_HOME", home, () => snapshotVibe({
    maxMsgs: 10, projectPath: "/repo", sourceCwd: "/repo", agentSessionId: ID,
    outDir: temp("antgrid-vibe-out-"), signal: new AbortController().signal,
  }))).toBeUndefined();
  expect(await run(home)).toBeDefined();
});

test("Vibe fork is a terminal-transcript fork that carries the snapshot", () => {
  expect(vibeFork.kind).toBe("terminal-transcript");
  expect(vibeFork.snapshot).toBe(snapshotVibe);
});
