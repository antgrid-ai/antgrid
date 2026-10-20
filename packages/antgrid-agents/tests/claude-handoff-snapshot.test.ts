import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { safeJoin } from "../src/agents/handoff";
import { resolveClaudeProjectsRoot } from "../src/agents/claude-code/handoff-snapshot";
import { claudeFork } from "../src/agents/claude-code/fork";
import { claudeProjectSlug } from "../src/agents/claude-code/transcript-read";
import { withEnv } from "./fixtures/with-env";

const ID = "11111111-2222-4333-8444-555555555555";
let root: string;
let projects: string;
let out: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "claude-snap-"));
  projects = join(root, "projects");
  out = join(root, "out");
  mkdirSync(projects);
  mkdirSync(out);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

function transcript(dir: string, id = ID, body = "hello"): string {
  mkdirSync(join(projects, dir), { recursive: true });
  const path = join(projects, dir, `${id}.jsonl`);
  const lines = [
    JSON.stringify({ type: "file-history-snapshot" }),
    JSON.stringify({ type: "user", sessionId: id, message: { role: "user", content: body } }),
  ];
  writeFileSync(path, `${lines.join("\n")}\n`);
  return path;
}

function opts(extra: Record<string, unknown> = {}) {
  return {
    maxMsgs: 10,
    projectPath: join(root, "project"),
    sourceCwd: join(root, "checkout"),
    outDir: out,
    signal: new AbortController().signal,
    claudeProjectsRoot: projects,
    agentSessionId: ID,
    ...extra,
  };
}

test("prefers a hook transcript path inside the projects root", async () => {
  const hinted = transcript("elsewhere", ID, "from hint");
  transcript(claudeProjectSlug(join(root, "checkout")), ID, "from slug");
  const snapshot = await claudeFork.snapshot(opts({ transcriptPath: hinted }));
  expect(readFileSync(join(out, "claude-code.jsonl"), "utf8")).toContain("from hint");
  expect(snapshot?.primary).toBe("claude-code.jsonl");
  expect(snapshot?.method).toBe("copy");
});

test("a hook transcriptPath outside the store is ignored", async () => {
  const outside = join(root, "outside");
  mkdirSync(outside);
  const hinted = join(outside, `${ID}.jsonl`);
  writeFileSync(hinted, `${JSON.stringify({ sessionId: ID, message: "planted" })}\n`);
  expect(await claudeFork.snapshot(opts({ transcriptPath: hinted }))).toBeUndefined();

  transcript("real", ID, "from store");
  const snapshot = await claudeFork.snapshot(opts({ transcriptPath: hinted }));
  expect(snapshot).toBeDefined();
  expect(readFileSync(join(out, "claude-code.jsonl"), "utf8")).toContain("from store");
});

test("a file whose records name another session is not accepted", async () => {
  transcript("dir", ID, "x");
  writeFileSync(join(projects, "dir", `${ID}.jsonl`), `${JSON.stringify({ sessionId: "other" })}\n`);
  expect(await claudeFork.snapshot(opts())).toBeUndefined();
});

test("accepts a resumed file whose own id only appears after the copied history", async () => {
  mkdirSync(join(projects, "dir"), { recursive: true });
  const filler = JSON.stringify({ type: "assistant", sessionId: "older", message: "x".repeat(4000) });
  const lines = [
    ...Array.from({ length: 200 }, () => filler),
    JSON.stringify({ type: "user", sessionId: ID, message: { role: "user", content: "after resume" } }),
  ];
  writeFileSync(join(projects, "dir", `${ID}.jsonl`), `${lines.join("\n")}\n`);
  const snapshot = await claudeFork.snapshot(opts());
  expect(snapshot?.method).toBe("copy");
  expect(readFileSync(join(out, "claude-code.jsonl"), "utf8")).toContain("after resume");
});

test("finds a worktree session by the sourceCwd slug, then projectPath slug, then glob", async () => {
  const cwdSlug = claudeProjectSlug(join(root, "checkout"));
  const projectSlug = claudeProjectSlug(join(root, "project"));
  transcript("zzz-other", ID, "glob");
  transcript(projectSlug, ID, "project slug");
  transcript(cwdSlug, ID, "cwd slug");
  await claudeFork.snapshot(opts());
  expect(readFileSync(join(out, "claude-code.jsonl"), "utf8")).toContain("cwd slug");

  rmSync(join(projects, cwdSlug), { recursive: true });
  rmSync(out, { recursive: true });
  mkdirSync(out);
  await claudeFork.snapshot(opts());
  expect(readFileSync(join(out, "claude-code.jsonl"), "utf8")).toContain("project slug");

  rmSync(join(projects, projectSlug), { recursive: true });
  rmSync(out, { recursive: true });
  mkdirSync(out);
  await claudeFork.snapshot(opts());
  expect(readFileSync(join(out, "claude-code.jsonl"), "utf8")).toContain("glob");
});

test("honours CLAUDE_CONFIG_DIR", () => {
  expect(resolveClaudeProjectsRoot(undefined, { CLAUDE_CONFIG_DIR: join(root, "config") })).toBe(join(root, "config", "projects"));
  expect(resolveClaudeProjectsRoot("/seam", { CLAUDE_CONFIG_DIR: "/config" })).toBe("/seam");
  expect(resolveClaudeProjectsRoot(undefined, {})).toMatch(/\.claude[\\/]projects$/);
});

test("lists subagents and tool-results as references, never copies them", async () => {
  const path = transcript("p");
  mkdirSync(join(projects, "p", ID, "subagents"), { recursive: true });
  mkdirSync(join(projects, "p", ID, "tool-results"), { recursive: true });
  writeFileSync(join(projects, "p", ID, "subagents", "a.jsonl"), "{}\n");
  const snapshot = await claudeFork.snapshot(opts());
  expect(snapshot?.references.map((r) => r.path.split(/[\\/]/).pop()).sort()).toEqual(["subagents", "tool-results"]);
  expect(snapshot?.files.map((f) => f.name)).toEqual(["claude-code.jsonl"]);
  expect(path).toBeTruthy();
});

test("returns undefined with no session id, an unsafe id, or no store (and never reads a real home)", async () => {
  expect(await claudeFork.snapshot(opts({ agentSessionId: undefined }))).toBeUndefined();
  expect(await claudeFork.snapshot(opts({ agentSessionId: "../escape" }))).toBeUndefined();
  expect(await claudeFork.snapshot(opts())).toBeUndefined();
  transcript("p");
  expect(await withEnv("CLAUDE_CONFIG_DIR", root, () => claudeFork.snapshot({ ...opts(), claudeProjectsRoot: undefined }))).toBeUndefined();
  expect(await claudeFork.snapshot(opts())).toBeDefined();
});

test("every emitted file name passes safeJoin", async () => {
  transcript("p");
  const snapshot = await claudeFork.snapshot(opts());
  for (const file of snapshot!.files) expect(() => safeJoin(out, file.name)).not.toThrow();
});
