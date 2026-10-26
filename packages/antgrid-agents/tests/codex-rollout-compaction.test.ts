// Compaction checkpoints as codex 0.146-0.156 wrote them: `message` empty and
// either no retained_context or one whose lists are empty, so the only
// plaintext left is the user's messages in replacement_history.
import { afterAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readLastCodexMessages } from "../src/agents/codex/rollout-read";

const dir = mkdtempSync(join(tmpdir(), "ab-codex-compaction-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const meta = { turn_id: "019a0000-0000-7000-8000-000000000001", create_time: 1792000000, content_item_kinds: ["unknown"] };
const userEntry = (id: string, ...content: object[]) => ({
  type: "message",
  id,
  role: "user",
  content,
  internal_chat_message_metadata_passthrough: meta,
});
const text = (value: string) => ({ type: "input_text", text: value });

const replacementHistory = [
  userEntry("msg_1", text("# AGENTS.md instructions for /workspace/project\n\nbe terse")),
  userEntry("msg_2", text("<environment_context>\n  <cwd>/workspace/project</cwd>\n</environment_context>")),
  userEntry("msg_3", text("rename the parser")),
  { type: "message", id: "msg_4", role: "developer", content: [text("developer instructions")], internal_chat_message_metadata_passthrough: meta },
  // Sub-agent traffic: plaintext, but neither side is the user or the model's reply.
  {
    type: "agent_message",
    id: "msg_5",
    author: "/root",
    recipient: "/root/worker",
    content: [text("audit the parser"), { type: "encrypted_content", encrypted_content: "opaque" }],
    internal_chat_message_metadata_passthrough: meta,
  },
  userEntry("msg_6", text("# Files mentioned by the user:\n\n## parser.ts: src/parser.ts\n\n## My request for Codex:\nand update the tests")),
  { type: "compaction", id: "cmp_1", encrypted_content: "opaque", internal_chat_message_metadata_passthrough: { turn_id: meta.turn_id } },
];

const windows = {
  window_number: 2,
  first_window_id: "019a0000-0000-7000-8000-0000000000a1",
  previous_window_id: "019a0000-0000-7000-8000-0000000000a1",
  window_id: "019a0000-0000-7000-8000-0000000000a2",
};

const rollout = (name: string, compacted: object) => {
  const path = join(dir, name);
  const lines = [
    { timestamp: "2026-09-01T10:00:00.000Z", ordinal: 1, type: "event_msg", payload: { type: "user_message", message: "dropped by the compaction" } },
    { timestamp: "2026-09-01T10:05:00.000Z", ordinal: 2, type: "compacted", payload: compacted },
  ];
  writeFileSync(path, lines.map((line) => JSON.stringify(line)).join("\n") + "\n", "utf8");
  return path;
};

describe("codex compaction without retained turns", () => {
  it("keeps the user's own replacement_history messages when retained_context is absent", async () => {
    const path = rollout("rollout-no-retained.jsonl", {
      message: "",
      replacement_history: replacementHistory,
      ...windows,
      compaction_response_id: null,
      latest_token_usage_record: null,
    });
    expect(await readLastCodexMessages(path, 10)).toEqual(["rename the parser", "and update the tests"]);
  });

  it("keeps the user's own replacement_history messages when retained_context is empty", async () => {
    const path = rollout("rollout-empty-retained.jsonl", {
      message: "",
      replacement_history: replacementHistory,
      guardian_history: [],
      retained_context: {
        verified_answers: [],
        incomplete: false,
        user_messages: [],
        user_messages_incomplete: true,
        assistant_messages: [],
        assistant_messages_incomplete: false,
        next_order: 0,
      },
      ...windows,
      compaction_response_id: "resp_synthetic",
    });
    expect(await readLastCodexMessages(path, 10)).toEqual(["rename the parser", "and update the tests"]);
  });
});
