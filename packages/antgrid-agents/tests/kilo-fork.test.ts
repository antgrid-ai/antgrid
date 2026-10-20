import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { AGENTS, BY_HOOK_NAME } from "../src/agents/registry";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
import { AntgridSessionIdentity } from "../assets/kilo/plugin";
import { prepareCliTerminalLaunch } from "../src/agents/terminal-launch";
import { createAgentRunScope } from "../src/run-scope";
import { logger, withAgentHost } from "../src/host";

const savedEnv = { ...process.env };
const directories: string[] = [];
afterEach(() => {
  for (const key of ["KILO_CONFIG", "KILO_PURE", "KILO_CONFIG_CONTENT", "ANTGRID_API_PORT", "ANTGRID_TERMINAL_ID", "ANTGRID_RUN_ID"]) {
    if (savedEnv[key] === undefined) delete process.env[key];
    else process.env[key] = savedEnv[key];
  }
  for (const dir of directories.splice(0)) rmSync(dir, { recursive: true, force: true });
});

test("Kilo preserves native fork identity and resumes the resulting conversation", async () => {
  const spec = AGENTS.kilo;
  expect(spec.fork.kind).toBe("native-fork");
  expect(spec.cli?.nativeForkArgs?.("ses_source")).toEqual(["--session", "ses_source", "--fork"]);
  expect(spec.cli?.resume?.("ses_fork")).toEqual(["--session", "ses_fork"]);
  expect(spec.fork.decodeLegacyArgs?.(["--session", "ses_source", "--fork"])).toBe("ses_source");
  expect(spec.fork.decodeLegacyArgs?.(["--session", "ses_source"])).toBeUndefined();
  expect(BY_HOOK_NAME.kilo).toBe("kilo");
});

test("Kilo injects a bundled identity plugin alongside MCP while preserving user config", () => {
  delete process.env.KILO_CONFIG;
  delete process.env.KILO_PURE;
  process.env.KILO_CONFIG_CONTENT = JSON.stringify({ model: "test/model", plugin: ["user-plugin"] });
  const abDir = mkdtempSync(join(tmpdir(), "kilo-fork-"));
  directories.push(abDir);
  const options = { abDir, hookCommand: { binary: "bridge", preargs: [] }, mcpCommand: { binary: "bridge", preargs: ["mcp"] } };
  const launch = augmentAgentLaunch("kilo", options);
  const config = JSON.parse(readFileSync(launch.env.KILO_CONFIG!, "utf8"));
  expect(readFileSync(fileURLToPath(config.plugin[0]), "utf8")).toContain("AntgridSessionIdentity");
  expect(JSON.parse(launch.env.KILO_CONFIG_CONTENT!).plugin).toEqual(["user-plugin"]);
  expect(JSON.parse(launch.env.KILO_CONFIG_CONTENT!).mcp.antgrid.command).toEqual(["bridge", "mcp"]);
  expect(launch.observation?.titles).toBe(true);
  expect(launch.observation?.notifications).toBe(false);
  process.env.KILO_CONFIG = "user.json";
  expect(augmentAgentLaunch("kilo", options).env.KILO_CONFIG).toBeUndefined();
  delete process.env.KILO_CONFIG;
  process.env.KILO_PURE = "1";
  expect(augmentAgentLaunch("kilo", options).observation?.titles).toBe(false);
});

test("project-default Kilo launches inject identity hooks and resume recorded sessions", () => {
  delete process.env.KILO_CONFIG;
  delete process.env.KILO_PURE;
  const storeDir = mkdtempSync(join(tmpdir(), "kilo-default-"));
  directories.push(storeDir);
  const scope = createAgentRunScope({ runId: "test", isCurrent: () => true, emit() {} });
  for (const conversation of [{ kind: "fresh" }, { kind: "resume", sessionId: "ses_saved" }] as const) {
    const launch = withAgentHost({
      logger: { ...logger, child() { return this; }, warn() {} },
      stateDirectory: () => storeDir,
      hookCommand: () => ({ binary: "bridge", preargs: [] }),
      killChildTree: async () => {},
      stripInheritedCertOverrides: env => env,
    }, () => prepareCliTerminalLaunch({
      configured: { name: "kilo", command: "custom-kilo", args: ["--configured"] },
      conversation, cwd: storeDir, storeDir, approvalPolicy: "default", signal: scope.signal, scope,
    }));
    expect(launch.command).toBe("custom-kilo");
    expect(launch.env.KILO_CONFIG).toBeDefined();
    expect(launch.observation?.titles).toBe(true);
    expect(launch.args).toEqual(conversation.kind === "resume"
      ? ["--configured", "--session", "ses_saved"] : ["--configured"]);
    expect(launch.resumed).toBe(conversation.kind === "resume");
  }
});

test("Kilo identity plugin reports root creation and updates in order, ignoring subagents", async () => {
  const posts: unknown[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(req) {
    expect(new URL(req.url).pathname).toBe("/session-title");
    posts.push(await req.json());
    return new Response("ok");
  } });
  try {
    process.env.ANTGRID_API_PORT = String(server.port);
    process.env.ANTGRID_TERMINAL_ID = "terminal";
    process.env.ANTGRID_RUN_ID = "run";
    const plugin = await AntgridSessionIdentity();
    const emit = (type: string, id: string, parentID?: string) => plugin.event({ event: { type, properties: { info: { id, parentID } } } });
    await Promise.all([
      emit("session.created", "source"),
      emit("session.updated", "child", "source"),
      emit("session.created", "fork"),
      emit("session.updated", "fork"),
      emit("session.deleted", "source"),
    ]);
    expect(posts).toEqual(["source", "fork", "fork"].map(sessionId => ({ terminalId: "terminal", runId: "run", sessionId, agent: "kilo" })));
    delete process.env.ANTGRID_TERMINAL_ID;
    await emit("session.updated", "unowned");
    expect(posts).toHaveLength(3);
  } finally {
    server.stop(true);
  }
});
