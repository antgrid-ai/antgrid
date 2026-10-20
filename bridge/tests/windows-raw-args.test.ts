import { afterEach, describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentRunScope } from "antgrid-agents/contracts";
import { prepareTerminalLaunch } from "../src/agent-runtime";

describe("Windows terminal launch with per-session args", () => {
  const realPlatform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const dirs: string[] = [];
  afterEach(() => {
    Object.defineProperty(process, "platform", realPlatform);
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
  });

  async function launch(rawArgs: string, extra: { initialPrompt?: string; resume?: string } = {}) {
    Object.defineProperty(process, "platform", { ...realPlatform, value: "win32" });
    const storeDir = mkdtempSync(join(tmpdir(), "ab-win-raw-"));
    dirs.push(storeDir);
    const scope = createAgentRunScope({ runId: "run", isCurrent: () => true, emit: () => {} });
    const prepared = await prepareTerminalLaunch({
      tool: "claude-code",
      configured: { name: "claude-code", command: "claude" },
      rawArgs,
      conversation: extra.resume ? { kind: "resume", sessionId: extra.resume } : { kind: "fresh" },
      initialPrompt: extra.initialPrompt,
      approvalPolicy: "default",
      storeDir,
      cwd: storeDir,
      signal: scope.signal,
      scope,
    });
    return { ...prepared, storeDir };
  }

  // Folding these into a cmd.exe line delivered claude a quoted --plugin-dir,
  // a positional "--mcp-config=…" and `--chrome -- <first word>`.
  test("keeps the MCP config, plugin dir, user flag and prompt as discrete argv", async () => {
    const prepared = await launch("--chrome", { initialPrompt: "fix the bug" });
    expect(prepared.command).toBe("claude");
    expect(prepared.invocationKind).toBe("exec");
    expect(prepared.args).toContain(`--mcp-config=${join(prepared.storeDir, "mcp", "claude.json")}`);
    expect(prepared.args.slice(-3)).toEqual(["--chrome", "--", "fix the bug"]);
    expect(prepared.args.some((a) => a.includes('"'))).toBe(false);
    expect(prepared.promptDelivery).toBe("included");
  });

  test("a resumed launch carries no stray positional before the user's flags", async () => {
    const prepared = await launch("--chrome", { resume: "sess-1" });
    expect(prepared.invocationKind).toBe("exec");
    expect(prepared.args[0]).toBe("--plugin-dir");
    expect(prepared.args.slice(-3)).toEqual(["--resume", "sess-1", "--chrome"]);
  });

  test("a multi-line prompt stays one argument", async () => {
    const prepared = await launch("--model sonnet", { initialPrompt: "line one\nline two" });
    expect(prepared.args.slice(-4)).toEqual(["--model", "sonnet", "--", "line one\nline two"]);
  });
});
