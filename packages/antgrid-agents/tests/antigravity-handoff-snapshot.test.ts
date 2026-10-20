import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { safeJoin } from "../src/agents/handoff";
import { antigravityFork } from "../src/agents/antigravity/fork";

const ID = "5d1c0a52-1111-4222-8333-444444444444";
let root: string;
let home: string;
let out: string;
let brain: string;
let logs: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "agy-snap-"));
  home = join(root, "agy");
  out = join(root, "out");
  brain = join(home, "brain", ID);
  logs = join(brain, ".system_generated", "logs");
  mkdirSync(logs, { recursive: true });
  mkdirSync(out);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

function opts(extra: Record<string, unknown> = {}) {
  return {
    maxMsgs: 10,
    projectPath: join(root, "project"),
    sourceCwd: join(root, "project"),
    outDir: out,
    signal: new AbortController().signal,
    antigravityHome: home,
    agentSessionId: ID,
    ...extra,
  };
}

test("copies the full transcript, drops a torn tail, and adds small plan artifacts", async () => {
  writeFileSync(join(logs, "transcript_full.jsonl"), '{"type":"USER_INPUT"}\n{"torn');
  writeFileSync(join(logs, "transcript.jsonl"), "compact\n");
  writeFileSync(join(brain, "plan.md"), "# plan\n");
  writeFileSync(join(brain, "walkthrough.md"), "x".repeat(1024 * 1024 + 1));
  mkdirSync(join(brain, ".system_generated", "steps"));

  const snapshot = await antigravityFork.snapshot(opts());
  expect(snapshot?.primary).toBe("antigravity-transcript.jsonl");
  expect(readFileSync(join(out, "antigravity-transcript.jsonl"), "utf8")).toBe('{"type":"USER_INPUT"}\n');
  expect(snapshot?.files.map((f) => f.name)).toEqual(["antigravity-transcript.jsonl", "antigravity-plan.md"]);
  expect(snapshot?.warnings.join(" ")).toContain("walkthrough.md");
  expect(snapshot?.references.map((r) => r.path.split(/[\\/]/).pop())).toEqual(["steps"]);
  expect(existsSync(join(out, "antigravity-walkthrough.md"))).toBe(false);
  for (const file of snapshot!.files) expect(() => safeJoin(out, file.name)).not.toThrow();
});

test("accepts a hook path that is this conversation's transcript inside the brain dir", async () => {
  writeFileSync(join(logs, "transcript_full.jsonl"), "{}\n");
  const snapshot = await antigravityFork.snapshot(opts({ transcriptPath: join(logs, "transcript_full.jsonl") }));
  expect(snapshot?.files[0]?.sourcePath?.replace(/\\/g, "/")).toContain(`brain/${ID}/.system_generated/logs/transcript_full.jsonl`);
});

test("a hook transcriptPath outside the store is ignored", async () => {
  const planted = join(root, "planted.jsonl");
  writeFileSync(planted, "planted\n");
  expect(await antigravityFork.snapshot(opts({ transcriptPath: planted }))).toBeUndefined();

  writeFileSync(join(logs, "transcript_full.jsonl"), "real\n");
  await antigravityFork.snapshot(opts({ transcriptPath: planted }));
  expect(readFileSync(join(out, "antigravity-transcript.jsonl"), "utf8")).toBe("real\n");
});

test("another conversation's transcript is not accepted as a hint", async () => {
  const other = join(home, "brain", "other-id", ".system_generated", "logs");
  mkdirSync(other, { recursive: true });
  writeFileSync(join(other, "transcript_full.jsonl"), "other\n");
  expect(await antigravityFork.snapshot(opts({ transcriptPath: join(other, "transcript_full.jsonl") }))).toBeUndefined();
});

test("returns undefined with no transcript yet, an unsafe id, or no seam under test", async () => {
  expect(await antigravityFork.snapshot(opts())).toBeUndefined();
  expect(await antigravityFork.snapshot(opts({ agentSessionId: "../x" }))).toBeUndefined();
  writeFileSync(join(logs, "transcript_full.jsonl"), "{}\n");
  expect(await antigravityFork.snapshot(opts({ antigravityHome: undefined }))).toBeUndefined();
});
