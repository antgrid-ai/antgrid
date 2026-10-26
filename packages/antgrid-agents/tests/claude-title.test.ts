import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveClaudeTranscriptTitle } from "../src/agents/claude-code/title";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "claude-title-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

function transcript(records: object[]): string {
  const path = join(dir, "session.jsonl");
  writeFileSync(path, records.map((r) => JSON.stringify(r)).join("\n") + "\n");
  return path;
}

const base = { isSidechain: false, userType: "external", entrypoint: "cli", version: "2.1.310" };

// Shape of a background task's completion as Claude Code 2.1.310 writes it: no
// isMeta, only an origin naming where it came from.
const taskNotification = {
  ...base,
  type: "user",
  permissionMode: "auto",
  origin: { kind: "task-notification", producer: "session-task", runId: "run-1" },
  promptSource: "system",
  turnOrigin: "task_notification",
  queueSkipAttachments: true,
  message: {
    role: "user",
    content:
      "<task-notification>\n<task-id>task-1</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<output-file>/tmp/out.txt</output-file>\n<status>completed</status>\n<summary>Background command finished</summary>\n</task-notification>",
  },
};

test("a session resumed from a compaction summary is not named after a task notification", async () => {
  const path = transcript([
    {
      ...base,
      type: "user",
      isCompactSummary: true,
      isVisibleInTranscriptOnly: true,
      message: { role: "user", content: "This session is being continued from a previous conversation. Summary: example." },
    },
    taskNotification,
    { ...base, type: "user", origin: { kind: "human" }, promptSource: "user", message: { role: "user", content: "Add a retry to the uploader" } },
  ]);
  expect(await resolveClaudeTranscriptTitle(path)).toEqual({ title: "Add a retry to the uploader", kind: "first-message" });
});

test("a prompt written before records carried an origin still names the session", async () => {
  const path = transcript([{ ...base, version: "2.1.200", type: "user", message: { role: "user", content: "Explain the cache layer" } }]);
  expect(await resolveClaudeTranscriptTitle(path)).toEqual({ title: "Explain the cache layer", kind: "first-message" });
});
