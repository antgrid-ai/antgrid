import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeNativeForkArgs } from "../../packages/antgrid-agents/src/agents/claude-code/fork";
import { codexNativeForkArgs } from "../../packages/antgrid-agents/src/agents/codex/fork";
import { opencodeNativeForkArgs } from "../../packages/antgrid-agents/src/agents/opencode/fork";
import { terminalOnlyFork } from "../../packages/antgrid-agents/src/agents/fork-handoff";
import type { HandoffEvent, HandoffSnapshot } from "antgrid-agents/handoff";

const dirs: string[] = [];

afterEach(async () => {
  await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })));
});

describe("agent fork handoffs", () => {
  test("terminal-only adapters have no store to snapshot and summarize the scrollback", async () => {
    const dir = await mkdtemp(join(tmpdir(), "antgrid-fork-"));
    dirs.push(dir);
    await writeFile(join(dir, "terminal-scrollback.txt"), "Existing terminal context");
    const adapter = terminalOnlyFork();
    await expect(adapter.snapshot({
      maxMsgs: 20, projectPath: "/project", sourceCwd: "/project", outDir: dir, signal: new AbortController().signal,
    })).resolves.toBeUndefined();

    const manifest: HandoffSnapshot = {
      agent: "kimi", method: "copy", primary: "terminal-scrollback.txt", files: [], references: [], redactions: [], warnings: [],
    };
    const events: HandoffEvent[] = [];
    await adapter.events(dir, manifest, (event) => events.push(event), new AbortController().signal);
    expect(events).toEqual([{ kind: "assistant", text: "Existing terminal context", at: "terminal-scrollback.txt" }]);
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
