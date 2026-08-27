import { describe, it, expect, mock } from "bun:test";
import { buildClaudeEnv, createPersistentPromptStream, resolveClaudeBinary } from "../src/agents/claude-code/spawn";

describe("buildClaudeEnv", () => {
  it("strips API keys and sets the required env", () => {
    const env = buildClaudeEnv({
      ANTHROPIC_API_KEY: "sk-secret", OPENAI_API_KEY: "sk-other",
      USERPROFILE: "C:\\Users\\x", PATH: "/usr/bin",
    });
    expect(env.ANTHROPIC_API_KEY).toBeUndefined();
    expect(env.OPENAI_API_KEY).toBeUndefined();
    expect(env.CLAUDE_CODE_ENTRYPOINT).toBe("cli");
    expect(env.ENABLE_TOOL_SEARCH).toBe("auto:2");
    expect(env.CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT).toBe("0");
    expect(env.CLAUDE_CODE_DISABLE_AGENT_VIEW).toBe("1");
  });

  it("does not clobber a user-set ENABLE_TOOL_SEARCH", () => {
    const env = buildClaudeEnv({ ENABLE_TOOL_SEARCH: "false", PATH: "/usr/bin" });
    expect(env.ENABLE_TOOL_SEARCH).toBe("false");
  });

  // The gate is a bare truthiness check on the string, so "0" disables agent
  // view too. Deferring still matters: an empty value is the only way back in.
  it("does not clobber a user-set CLAUDE_CODE_DISABLE_AGENT_VIEW", () => {
    const env = buildClaudeEnv({ CLAUDE_CODE_DISABLE_AGENT_VIEW: "", PATH: "/usr/bin" });
    expect(env.CLAUDE_CODE_DISABLE_AGENT_VIEW).toBe("");
  });
});

describe("resolveClaudeBinary", () => {
  it("returns an explicit path hint verbatim", () => {
    expect(resolveClaudeBinary("C:\\tools\\claude.exe")).toBe("C:\\tools\\claude.exe");
    expect(resolveClaudeBinary("/usr/local/bin/claude")).toBe("/usr/local/bin/claude");
  });
});

describe("createPersistentPromptStream", () => {
  it("yields pushed messages then returns after end()", async () => {
    const { iterable, controller } = createPersistentPromptStream();
    const got: any[] = [];
    const pump = (async () => { for await (const m of iterable) got.push(m); })();
    controller.push({ type: "user", message: { role: "user", content: "a" }, parent_tool_use_id: null });
    controller.push({ type: "user", message: { role: "user", content: "b" }, parent_tool_use_id: null });
    // let the generator drain the queue
    await new Promise((r) => setTimeout(r, 10));
    expect(controller.isEnded()).toBe(false);
    controller.end("test");
    await pump;
    expect(got.map((m) => m.message.content)).toEqual(["a", "b"]);
    expect(controller.isEnded()).toBe(true);
  });
});

describe("spawnClaude forwarding", () => {
  it("forwards extraArgs and merges extraEnv over buildClaudeEnv", async () => {
    let captured: any;
    const stub: any = {
      async *[Symbol.asyncIterator]() {},
      interrupt: async () => {}, setModel: async () => {},
      setPermissionMode: async () => {}, supportedCommands: async () => [],
      supportedModels: async () => [], initializationResult: async () => ({}),
      applyFlagSettings: async () => {}, close: () => {},
    };
    mock.module("@anthropic-ai/claude-agent-sdk", () => ({
      query: (o: any) => { captured = o.options; return stub; },
    }));
    // Re-import so the module binds against the mocked query.
    const { spawnClaude } = await import("../src/agents/claude-code/spawn");

    spawnClaude({
      cwd: "/tmp/proj",
      canUseTool: (async () => ({ behavior: "allow", updatedInput: {} })) as any,
      onStderr: () => {},
      abortController: new AbortController(),
      extraArgs: { "plugin-dir": "/plugins/claude" },
      extraEnv: { ANTGRID_TERMINAL_ID: "slot-1", ANTGRID_API_PORT: "8790" },
    });

    expect(captured.extraArgs).toEqual({ "plugin-dir": "/plugins/claude" });
    expect(captured.env.ANTGRID_TERMINAL_ID).toBe("slot-1");
    expect(captured.env.ANTGRID_API_PORT).toBe("8790");
    // buildClaudeEnv still applied — it deletes ANTHROPIC_API_KEY.
    expect(captured.env.ANTHROPIC_API_KEY).toBeUndefined();
  });
});
