import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeForkHandoff, claudeNativeForkArgs } from "../src/agents/claude-code/fork";
import { codexNativeForkArgs } from "../src/agents/codex/fork";
import { opencodeNativeForkArgs } from "../src/agents/opencode/fork";
import { terminalForkHandoff } from "../src/agents/fork-handoff";

const dirs: string[] = [];

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("agent fork handoffs", () => {
  test("Claude adapter normalizes its captured hook transcript", async () => {
    const dir = await mkdtemp(join(tmpdir(), "antgrid-fork-"));
    dirs.push(dir);
    const transcriptPath = join(dir, "session.jsonl");
    await writeFile(transcriptPath, [
      JSON.stringify({ type: "user", message: { content: "Inspect the failing test." } }),
      JSON.stringify({ type: "assistant", message: { content: [{ type: "text", text: "I found the regression." }] } }),
    ].join("\n"));

    await expect(claudeForkHandoff({
      maxMsgs: 20,
      projectPath: dir,
      transcriptPath,
    })).resolves.toBe("[Claude Code conversation]\nInspect the failing test.\n\nI found the regression.");
  });

  test("terminal-only adapters never invent provider ids or paths", async () => {
    const adapter = terminalForkHandoff("Kimi");
    await expect(adapter.handoff({
      maxMsgs: 20,
      projectPath: "/project",
      terminalTranscript: "Existing terminal context",
    })).resolves.toBe("[Kimi conversation]\nExisting terminal context");
  });

  test("native providers use fork rather than resume", () => {
    expect(claudeNativeForkArgs("claude-session")).toEqual([
      "--resume", "claude-session", "--fork-session",
    ]);
    expect(codexNativeForkArgs("codex-session")).toEqual(["fork", "codex-session"]);
    expect(opencodeNativeForkArgs("opencode-session")).toEqual([
      "--session", "opencode-session", "--fork",
    ]);
  });
});
