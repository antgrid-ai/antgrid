import { afterEach, beforeEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { safeJoin } from "../src/agents/handoff";
import { copilotFork } from "../src/agents/github-copilot/fork";
import { withEnv } from "./fixtures/with-env";

const ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
let root: string;
let home: string;
let out: string;
let session: string;
beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "copilot-snap-"));
  home = join(root, "copilot");
  out = join(root, "out");
  session = join(home, "session-state", ID);
  mkdirSync(session, { recursive: true });
  mkdirSync(out);
});
afterEach(() => rmSync(root, { recursive: true, force: true }));

const start = (id = ID) => JSON.stringify({ type: "session.start", data: { sessionId: id } });

function opts(extra: Record<string, unknown> = {}) {
  return {
    maxMsgs: 10,
    projectPath: join(root, "project"),
    sourceCwd: join(root, "project"),
    outDir: out,
    signal: new AbortController().signal,
    copilotHome: home,
    agentSessionId: ID,
    ...extra,
  };
}

test("copies events, workspace.yaml, checkpoints and files under flat indexed names; skips rewind snapshots", async () => {
  writeFileSync(join(session, "events.jsonl"), `${start()}\n{"type":"user.message"}\n{"torn":`);
  writeFileSync(join(session, "workspace.yaml"), "id: x\n");
  mkdirSync(join(session, "checkpoints"));
  writeFileSync(join(session, "checkpoints", "index.md"), "# index\n");
  writeFileSync(join(session, "checkpoints", "001-first.md"), "# first\n");
  mkdirSync(join(session, "files"));
  writeFileSync(join(session, "files", "Pasted Text.txt"), "pasted");
  writeFileSync(join(session, "files", "blob.bin"), Buffer.from([1, 0, 2]));
  mkdirSync(join(session, "rewind-file-snapshots"));
  writeFileSync(join(session, "rewind-file-snapshots", "tracking.json"), "{}");

  const snapshot = await copilotFork.snapshot(opts());
  expect(snapshot?.primary).toBe("copilot-events.jsonl");
  expect(snapshot?.files.map((f) => f.name)).toEqual([
    "copilot-events.jsonl",
    "copilot-workspace.yaml",
    "copilot-checkpoint-01.md",
    "copilot-checkpoint-02.md",
    "copilot-file-01",
  ]);
  expect(snapshot?.files.find((f) => f.name === "copilot-file-01")?.originalName).toBe("Pasted Text.txt");
  expect(snapshot?.references.map((r) => r.path.split(/[\\/]/).pop())).toEqual(["blob.bin"]);
  expect(readFileSync(join(out, "copilot-events.jsonl"), "utf8")).toBe(`${start()}\n{"type":"user.message"}\n`);
  expect(readFileSync(join(out, "copilot-file-01"), "utf8")).toBe("pasted");
  expect(existsSync(join(out, "tracking.json"))).toBe(false);
  for (const file of snapshot!.files) expect(() => safeJoin(out, file.name)).not.toThrow();
});

test("refuses a file whose session.start names another id", async () => {
  writeFileSync(join(session, "events.jsonl"), `${start("someone-else")}\n`);
  expect(await copilotFork.snapshot(opts())).toBeUndefined();
});

test("returns undefined before the first prompt, for a non-uuid id, and with no seam under test", async () => {
  expect(await copilotFork.snapshot(opts())).toBeUndefined();
  expect(await copilotFork.snapshot(opts({ agentSessionId: "../../etc" }))).toBeUndefined();
  writeFileSync(join(session, "events.jsonl"), `${start()}\n`);
  expect(await withEnv("COPILOT_HOME", home, () => copilotFork.snapshot(opts({ copilotHome: undefined })))).toBeUndefined();
  expect(await copilotFork.snapshot(opts())).toBeDefined();
});

// Mirrors a head Copilot 1.0.107 rotated for real: the link record (with its own
// key order and no checkpoint flag), a `checkpoint: true` replay of the whole
// conversation including synthesized shutdown/usage records, then new history.
// The archived history lives on in `events.1.jsonl`.
function rotatedSession(linkVersion = 1, linkSession = ID): void {
  let n = 0;
  const uuid = () => `00000000-0000-4000-8000-${String(++n).padStart(12, "0")}`;
  const record = (type: string, data: Record<string, unknown>, checkpoint: boolean) => JSON.stringify({
    type, data, id: uuid(), timestamp: "2026-01-01T00:00:00.000Z", parentId: null, ...(checkpoint ? { checkpoint: true } : {}),
  });
  const history = (checkpoint: boolean) => [
    record("session.start", { sessionId: ID, version: 1, producer: "copilot-agent" }, checkpoint),
    record("user.message", { content: "first prompt", transformedContent: "<ctx/>first prompt" }, checkpoint),
    record("assistant.message", { messageId: "m1", content: "first reply", toolRequests: [] }, checkpoint),
    record("tool.execution_start", { toolCallId: "call_1", toolName: "view", arguments: { path: "notes.txt" } }, checkpoint),
    record("tool.execution_complete", { toolCallId: "call_1", success: true, result: { content: "note body" } }, checkpoint),
    record("session.compaction_complete", { success: true, outcome: "applied", summaryContent: "summary one" }, checkpoint),
    record("user.message", { content: "second prompt" }, checkpoint),
  ];
  writeFileSync(join(session, "events.1.jsonl"), `${history(false).join("\n")}\n`);
  const link = JSON.stringify({
    id: uuid(), timestamp: "2026-01-01T00:00:00.000Z", parentId: null, type: "session.journal_link",
    data: { version: linkVersion, sessionId: linkSession, previousFile: "events.1.jsonl" },
  });
  writeFileSync(join(session, "events.jsonl"), `${[
    link,
    ...history(true),
    record("session.shutdown", { shutdownType: "routine" }, true),
    record("session.usage_checkpoint", {}, true),
    record("session.shutdown", { shutdownType: "routine" }, false),
    record("session.resume", { eventCount: 9 }, false),
    record("user.message", { content: "third prompt" }, false),
    record("assistant.message", { messageId: "m3", content: "third reply", toolRequests: [] }, false),
  ].join("\n")}\n`);
}

test("a rotated head is the whole transcript: every turn once, archived segments not copied", async () => {
  rotatedSession();
  const snapshot = await copilotFork.snapshot(opts());
  expect(snapshot?.files.map((f) => f.name)).toEqual(["copilot-events.jsonl"]);
  const events: Array<{ kind: string; text?: string; summary?: string; name?: string }> = [];
  await copilotFork.events(out, snapshot!, (e) => events.push(e as never), new AbortController().signal);
  expect(events.map((e) => `${e.kind}:${e.text ?? e.summary ?? e.name ?? ""}`)).toEqual([
    "user:first prompt",
    "assistant:first reply",
    "tool_call:view",
    "tool_result:view",
    "compaction:summary one",
    "user:second prompt",
    "user:third prompt",
    "assistant:third reply",
  ]);
});

test("refuses a rotated head linked to another session or in an unmeasured link version", async () => {
  rotatedSession(1, "someone-else");
  expect(await copilotFork.snapshot(opts())).toBeUndefined();
  rotatedSession(2);
  expect(await copilotFork.snapshot(opts())).toBeUndefined();
});
