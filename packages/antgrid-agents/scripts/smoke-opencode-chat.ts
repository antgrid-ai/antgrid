import assert from "node:assert/strict";
import { existsSync, mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { OpenCode } from "@opencode/client";
import { startOpencodeServer } from "../src/agents/opencode/server";
import { connectOpencode } from "../src/agents/opencode/spawn";
import { OpencodeDriver } from "../src/agents/opencode/chat-backend";
import { augmentAgentLaunch } from "../src/agent-launch-augmenter";
import { withAgentHost, type AgentHostServices, type AgentLogger } from "../src/host";
import type { AbMessage } from "../src/protocol";
import { Database } from "bun:sqlite";
import { readLastOpencodeMessages } from "../src/agents/opencode/db-read";
import { serializeOpencodeSession } from "../src/agents/handoff/opencode-serialize";
import { prepareOpencodeTerminal } from "../src/agents/opencode/terminal";
import { createAgentRunScope } from "../src/run-scope";

const binary = process.env.OPENCODE_SMOKE_BINARY;
if (!binary) throw new Error("Set OPENCODE_SMOKE_BINARY to the OpenCode executable to verify");
const root = mkdtempSync(join(tmpdir(), "antgrid-opencode2-smoke-"));
const cwd = join(root, "project");
mkdirSync(cwd);
const nativePlugin = join(cwd, "native-plugin");
mkdirSync(nativePlugin);
const pluginMarker = join(root, "native-plugin-loaded");
writeFileSync(join(nativePlugin, "server.ts"), `export default { id: "native-smoke", async setup() { await Bun.write(${JSON.stringify(pluginMarker)}, "loaded"); } };`);
const posts: Array<{ path: string; body: any }> = [];
const bridge = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
  posts.push({ path: new URL(request.url).pathname, body: await request.json() });
  return Response.json({ ok: true });
} });
const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
const host: AgentHostServices = {
  logger, stateDirectory: () => root, hookCommand: () => ({ binary: process.execPath, preargs: [] }),
  stripInheritedCertOverrides: (env) => env,
  killChildTree: async (child) => {
    if (process.platform === "win32" && child.pid) {
      const code = await Bun.spawn(["taskkill.exe", "/PID", String(child.pid), "/T", "/F"], { stdout: "ignore", stderr: "ignore" }).exited;
      if (code !== 0) child.kill();
    } else if (child.pid) {
      try { process.kill(-child.pid, "SIGTERM"); } catch { child.kill(); }
    } else child.kill();
  },
};
const mcpFile = join(root, "mcp.ts");
writeFileSync(mcpFile, `
  import { createInterface } from "node:readline";
  for await (const line of createInterface({ input: process.stdin })) {
    const request = JSON.parse(line);
    if (request.id === undefined) continue;
    const result = request.method === "initialize"
      ? { protocolVersion: "2024-11-05", capabilities: { tools: {} }, serverInfo: { name: "smoke", version: "1" } }
      : request.method === "tools/list"
        ? { tools: [{ name: "echo", description: "Smoke echo", inputSchema: { type: "object", properties: {} } }] }
        : request.method === "tools/call"
          ? { content: [{ type: "text", text: process.env.ANTGRID_TERMINAL_ID || "native" }] } : {};
    console.log(JSON.stringify({ jsonrpc: "2.0", id: request.id, result }));
  }
`);
let requests = 0;
const model = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
  const body = await request.json() as any;
  requests++;
  const completion = { id: "smoke", object: "chat.completion", created: 1, model: body.model,
    choices: [{ index: 0, message: { role: "assistant", content: "native-chat-ok" }, finish_reason: "stop" }],
    usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 },
  };
  if (!body.stream) return Response.json(completion);
  const chunks = [
    { ...completion, object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: "native-chat-" }, finish_reason: null }] },
    { ...completion, object: "chat.completion.chunk", choices: [{ index: 0, delta: { content: "ok" }, finish_reason: null }] },
    { ...completion, object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
  ];
  return new Response(chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n",
    { headers: { "Content-Type": "text/event-stream" } });
} });
writeFileSync(join(cwd, "opencode.json"), JSON.stringify({
  model: "smoke/chat", snapshots: false, update: "disable",
  instructions: ["native-instructions.md"],
  plugins: [pathToFileURL(nativePlugin).href],
  permissions: [{ action: "*", resource: "*", effect: "ask" }],
  providers: { smoke: { name: "Smoke provider", package: "@opencode/ai/providers/openai-compatible",
    settings: { baseURL: `http://127.0.0.1:${model.port}/v1`, apiKey: "smoke-only" },
    models: { chat: { name: "Smoke model", limit: { context: 32000, output: 2048 }, capabilities: { tools: true } } },
  } },
  mcp: { servers: { existing_native: { type: "local", command: [process.execPath, mcpFile] } } },
}));
writeFileSync(join(cwd, "native-instructions.md"), "Native instruction smoke marker.");
const augmentation = withAgentHost(host, () => augmentAgentLaunch("opencode", {
  mode: "terminal",
  abDir: root,
  mcpCommand: { binary: process.execPath, preargs: [mcpFile] },
}));
const env = { ...augmentation.env,
  XDG_CONFIG_HOME: join(root, "config"), XDG_DATA_HOME: join(root, "data"),
  XDG_STATE_HOME: join(root, "state"), XDG_CACHE_HOME: join(root, "cache"),
  OPENCODE_CONFIG_DIR: join(root, "config"),
  OPENCODE_DISABLE_MODELS_FETCH: "1", OPENCODE_DISABLE_FILEWATCHER: "1", OPENCODE_DISABLE_FFF: "1",
  OPENCODE_DISABLE_CLAUDE_CODE: "1", ANTGRID_TERMINAL_ID: "smoke-slot", ANTGRID_API_PORT: String(bridge.port),
};
const until = async (check: () => boolean | Promise<boolean>, label: string) => {
  const deadline = Date.now() + 20_000;
  while (!await check()) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting for ${label}`);
    await Bun.sleep(20);
  }
};
try {
  await withAgentHost(host, async () => {
    const scope = createAgentRunScope({ runId: "smoke", isCurrent: () => true, emit() {} });
    const savedEnv = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
    const terminalRequest = { configured: { name: "opencode", command: binary }, cwd, storeDir: root,
      approvalPolicy: "default" as const, scope, signal: scope.signal };
    Object.assign(process.env, env);
    try {
      const terminal = await prepareOpencodeTerminal({ ...terminalRequest, conversation: { kind: "fresh" } });
      assert(terminal.args.includes("--standalone"));
    } finally {
      for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
    }
    const server = await startOpencodeServer({ cwd, command: binary, env, timeoutMs: 30_000 });
    const api = OpenCode.make({ baseUrl: server.url, headers: server.headers });
    const { client } = connectOpencode(server, cwd);
    const frames: AbMessage[] = [];
    let sessionID = "";
    const driver = new OpencodeDriver({ sessionId: "smoke-slot", client, sendMessage: (message) => frames.push(message),
      onAgentSession: (id) => { sessionID = id; },
    });
    try {
      console.log("Runtime", (await api.server.info()).version);
      await driver.start();
      const config = await api.config.get({ location: { directory: cwd } });
      assert(config.some((entry) => entry.type === "document" && entry.info.instructions?.includes("native-instructions.md")));
      console.log("Native config loaded");
      await until(() => existsSync(pluginMarker), "native user plugin");
      await until(async () => (await api.plugin.list({ location: { directory: cwd } })).data.some((plugin) => plugin.id === "antgrid"), "Antgrid terminal plugin");
      await until(async () => {
        const servers = await api.mcp.list({ location: { directory: cwd } });
        return ["existing_native", "antgrid"].every((name) => servers.data.some((server) => server.name === name && server.status.status === "connected"));
      }, "both MCP connections");
      console.log("Native and Antgrid MCP connected");
      await driver.prompt("Return the native chat smoke marker.");
      try { await until(() => frames.some((frame) => frame.type === "agent:turn-end"), "chat completion"); }
      catch (error) { console.error("Chat frames", JSON.stringify(frames), "Model requests", requests); throw error; }
      console.log("Chat completed");
      await until(() => posts.some((post) => post.path === "/turn-start") && posts.some((post) => post.path === "/notify" && post.body.type === "idle"), "terminal plugin turn notifications");
      assert(posts.some((post) => post.path === "/session-title" && post.body.sessionId === sessionID));
      assert(frames.some((frame) => frame.type === "agent:item-delta"));
      assert(requests > 0);
      const history = await client.messages(sessionID);
      assert(history.some((message) => message.parts.some((part: any) => part.text === "native-chat-ok")));
      const user = history.find((message) => message.info.role === "user")!;
      const liveUsers = frames.filter((frame) => frame.type === "agent:item-added" && frame.item.kind === "message" && frame.item.role === "user");
      assert.equal(liveUsers.length, 1);
      assert(liveUsers.some((frame) => frame.type === "agent:item-added" && frame.item.kind === "message"
        && frame.item.text === "Return the native chat smoke marker."
        && frame.item.itemId === user.parts[0].id && frame.item.revertTarget?.messageId === user.info.id));
      const permission = api.permission.create({ sessionID, action: "smoke", resources: ["fixture"] });
      await until(() => frames.some((frame) => frame.type === "agent:permission-request"), "permission request");
      const approval = frames.find((frame) => frame.type === "agent:permission-request")!;
      if (approval.type === "agent:permission-request") driver.resolvePermission(approval.permissionId, "once");
      await permission;
      const form = await api.session.form.create({ sessionID, title: "MCP form smoke", fields: [
        { key: "count", type: "integer", required: true }, { key: "ok", type: "boolean", required: true },
      ] });
      await until(() => frames.filter((frame) => frame.type === "agent:question").length === 2, "form questions");
      for (const question of frames.filter((frame) => frame.type === "agent:question")) {
        driver.resolveQuestion(question.questionId, question.prompt.includes("count") ? "3" : "true");
      }
      let state = (await api.session.form.get({ sessionID, formID: form.id })).state;
      await until(async () => {
        state = (await api.session.form.get({ sessionID, formID: form.id })).state;
        return state.status !== "pending";
      }, "form reply");
      assert.equal(state.status, "answered");
      await until(() => posts.some((post) => post.path === "/handler-event" && post.body.event === "prompt_answered" && post.body.promptId === form.id), "terminal form resolution");
      console.log("Permissions and forms passed");
    } finally { await driver.dispose(); }
    const dbPath = join(env.XDG_DATA_HOME, "opencode", "opencode.db");
    assert(readLastOpencodeMessages(sessionID, 10, dbPath).includes("native-chat-ok"));
    const db = new Database(dbPath, { readonly: true });
    try { assert(serializeOpencodeSession(db, sessionID, { includeKiloBoard: false })?.doc.messages.some((message) => message.parts.some((part) => part.text === "native-chat-ok"))); }
    finally { db.close(); }
    let forkID: string;
    Object.assign(process.env, env);
    try {
      const fork = await prepareOpencodeTerminal({ ...terminalRequest, conversation: { kind: "fork", sourceSessionId: sessionID } });
      const created = await fork.createNativeFork!();
      forkID = created.nativeId;
      assert.notEqual(forkID, sessionID);
      assert(created.launch.args.includes(forkID));
      assert(!created.launch.args.includes("--fork"));
    } finally {
      for (const [key, value] of Object.entries(savedEnv)) {
        if (value === undefined) delete process.env[key]; else process.env[key] = value;
      }
      await scope.dispose();
    }
    const restarted = await startOpencodeServer({ cwd, command: binary, env, timeoutMs: 30_000 });
    const resumed = connectOpencode(restarted, cwd).client;
    try {
      const forkHistory = await resumed.messages(forkID);
      assert(forkHistory.some((message) => message.parts.some((part: any) => part.text === "native-chat-ok")));
      await resumed.revertMessages(forkID, forkHistory.find((message) => message.info.role === "user")!.info.id);
      assert(!(await resumed.messages(forkID)).some((message) => message.info.role === "user"));
      assert((await resumed.messages(sessionID)).some((message) => message.info.role === "user"));
    }
    finally { await resumed.dispose(); }
    console.log("Restart, fork, revert and transcript store passed");
  });
} finally { await model.stop(true); await bridge.stop(true); }
console.log("Smoke passed; isolated artifacts:", root);
