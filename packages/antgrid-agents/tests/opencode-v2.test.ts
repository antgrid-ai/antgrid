import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { OpenCodeEvent } from "@opencode/client";
import { normalizeMessage, OpencodeV2Events } from "../src/agents/opencode/v2-events";
import { connectOpencode } from "../src/agents/opencode/spawn";
import { prepareOpencodeTerminal } from "../src/agents/opencode/terminal";
import { opencodeUpgradeArgs, requireOpencodeV2 } from "../src/agents/opencode/version";
import { createAgentRunScope } from "../src/run-scope";
import { withAgentHost, type AgentHostServices, type AgentLogger } from "../src/host";
import { readOpencodeV2Messages } from "../src/agents/opencode/v2-store";
import { readLastOpencodeMessages } from "../src/agents/opencode/db-read";
import { serializeOpencodeSession } from "../src/agents/handoff/opencode-serialize";

const event = (type: string, data: object) => ({ type, data, id: "evt_fixture", created: 1 } as OpenCodeEvent);
const model = { id: "model", providerID: "provider" };

test("delivered native user messages match replay and retain their revert IDs", () => {
  const stream = new OpencodeV2Events();
  const base = { sessionID: "root", inboxID: "msg_question" };
  const payload = { text: "What changed?", metadata: { source: "chat" } };
  expect(stream.normalize(event("session.inbox.enqueued", {
    ...base, item: { type: "user", payload, delivery: "queue" },
  }))).toEqual([]);
  const replay = normalizeMessage({ id: base.inboxID, type: "user", ...payload, time: { created: 2 } });
  const delivered = { ...event("session.inbox.delivered", base), created: 2 };
  expect(stream.normalize(delivered)).toEqual([
    { type: "message.updated", properties: { info: { ...replay.info, sessionID: "root" } } },
    { type: "message.part.updated", properties: { part: { ...replay.parts[0], sessionID: "root" } } },
  ]);
  expect(stream.normalize(delivered)).toEqual([]);
});

test("inbox delivery keeps sessions isolated and excludes cancelled or non-user inputs", () => {
  const stream = new OpencodeV2Events();
  const base = { sessionID: "root", inboxID: "msg_question" };
  const enqueue = (data: object, type = "user") => stream.normalize(event("session.inbox.enqueued", {
    ...data, item: { type, payload: { text: "question" }, delivery: "queue" },
  }));
  enqueue(base);
  expect(stream.normalize(event("session.inbox.delivered", { ...base, sessionID: "other" }))).toEqual([]);
  expect(stream.normalize(event("session.inbox.delivered", base))).toHaveLength(2);
  enqueue(base);
  expect(stream.normalize(event("session.inbox.cancelled", base))).toEqual([]);
  expect(stream.normalize(event("session.inbox.delivered", base))).toEqual([]);
  enqueue(base, "synthetic");
  expect(stream.normalize(event("session.inbox.delivered", base))).toEqual([]);
});

test("native text, reasoning and MCP tools keep the same IDs and values on replay", () => {
  const stream = new OpencodeV2Events();
  const base = { sessionID: "root", assistantMessageID: "msg_answer" };
  stream.normalize(event("session.step.started", { ...base, model }));
  const text = stream.normalize(event("session.text.ended", { ...base, ordinal: 0, text: "answer" }))[0]!.properties.part;
  const reasoning = stream.normalize(event("session.reasoning.ended", { ...base, ordinal: 1, text: "thought" }))[0]!.properties.part;
  stream.normalize(event("session.tool.input.started", { ...base, id: "call", name: "antgrid_list_sessions" }));
  stream.normalize(event("session.tool.called", { ...base, id: "call", input: { filter: "mine" } }));
  const tool = stream.normalize(event("session.tool.success", { ...base, id: "call", content: [{ type: "text", text: "sessions" }] }))[0]!.properties.part;
  const history = normalizeMessage({ id: "msg_answer", type: "assistant", model, agent: "build", time: { created: 1 }, content: [
    { type: "text", text: "answer" }, { type: "reasoning", text: "thought" },
    { type: "tool", id: "call", name: "antgrid_list_sessions", time: { created: 1 },
      state: { status: "completed", input: { filter: "mine" }, content: [{ type: "text", text: "sessions" }] } },
  ] });
  expect(history.parts.map((part) => part.id)).toEqual([text.id, reasoning.id, tool.id]);
  expect(tool).toMatchObject({ tool: "antgrid_list_sessions", state: { status: "completed", input: { filter: "mine" }, output: "sessions" } });
  expect(history.parts[2]).toMatchObject({ id: tool.id, tool: tool.tool, state: tool.state });
  expect(stream.normalize(event("session.execution.succeeded", { sessionID: "root" }))).toEqual([
    { type: "session.idle", properties: { sessionID: "root" } },
  ]);
  expect(stream.normalize(event("session.execution.interrupted", { sessionID: "root" }))[0]?.properties.error.name).toBe("MessageAbortedError");
});

test("native forms and compaction IDs survive transport normalization", () => {
  const stream = new OpencodeV2Events();
  const form = { id: "form", sessionID: "global", title: "MCP", fields: [{ key: "ok", type: "boolean" }] };
  expect(stream.normalize(event("form.created", { form }))).toEqual([{ type: "form.created", properties: form }]);
  expect(stream.normalize(event("form.cancelled", { id: "form", sessionID: "global" }))[0]?.properties.id).toBe("form");
  const live = stream.normalize(event("session.compaction.started", { sessionID: "root", reason: "manual" }))[0]!.properties.part;
  const replay = normalizeMessage({ id: "msg_fixture", type: "compaction", time: { created: 1 }, reason: "manual", status: "completed", summary: "summary" });
  expect(live.id).toBe(replay.parts[0]?.id);
});

test("V2 client preserves native defaults, paginates history and reverts without touching files", async () => {
  const calls: Array<{ path: string; method: string; query: URLSearchParams; body: any }> = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url);
    calls.push({ path: url.pathname, method: request.method, query: url.searchParams,
      body: request.method === "GET" ? undefined : await request.json().catch(() => undefined) });
    if (url.pathname.endsWith("/message")) return Response.json(url.searchParams.has("cursor")
      ? { data: [], cursor: {} }
      : { data: [{ id: "msg_user", type: "user", time: { created: 1 }, text: "hello" }], cursor: { next: "page2" } });
    if (url.pathname.endsWith("/commit")) return new Response(null, { status: 204 });
    return Response.json({ data: {} });
  } });
  const { client } = connectOpencode({ url: server.url.href, close: async () => { await server.stop(true); } }, "/checkout");
  try {
    await client.prompt("root", "hello");
    expect(calls).toHaveLength(1);
    expect(calls[0]?.path).toBe("/api/session/root/prompt");
    expect(calls[0]?.body).toEqual({ text: "hello" });
    expect((await client.messages("root"))[0]?.parts[0].text).toBe("hello");
    expect(calls[1]?.query.get("order")).toBe("asc");
    expect(calls[2]?.query.get("cursor")).toBe("page2");
    expect(calls[2]?.query.has("order")).toBe(false);
    await client.revertMessages("root", "msg_user");
    expect(calls.slice(-2).map((call) => [call.path, call.body])).toEqual([
      ["/api/session/root/revert/stage", { messageID: "msg_user", files: false }],
      ["/api/session/root/revert/commit", undefined],
    ]);
  } finally { await client.dispose(); }
});

// 2.2.7 and 2.3.0 answer agent.list with no agents for the first few hundred
// milliseconds after a location boots, and command.list with no commands until
// the same load (2.2.6 already did for commands). Records as 2.3.0 lists them.
test("V2 client waits for the location's agents and commands before listing them", async () => {
  let agentRequests = 0;
  const agents = ["build", "plan", "general", "title"].map((id) => ({ id, name: id, mode: id === "general" ? "subagent" : "primary",
    hidden: id === "title", permissions: [], request: { settings: {}, headers: {}, body: {} } }));
  const commands = ["init", "review", "goal"].map((name) => ({ name, description: `${name} fixture` }));
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname;
    const loaded = agentRequests > 2;
    if (path === "/api/agent") return Response.json({ location: { directory: "/checkout" }, data: ++agentRequests > 3 ? agents : [] });
    if (path === "/api/command") return Response.json({ location: { directory: "/checkout" }, data: loaded ? commands : [] });
    return new Response(null, { status: 404 });
  } });
  const { client } = connectOpencode({ url: server.url.href, close: async () => { await server.stop(true); } }, "/checkout");
  try {
    const [listedCommands, listedAgents] = await Promise.all([client.listCommands(), client.listAgents()]);
    expect(listedAgents.map((agent) => agent.name)).toEqual(["build", "plan", "general", "title"]);
    expect(listedCommands.map((command) => command.name)).toEqual(["init", "review", "goal"]);
  } finally { await client.dispose(); }
});

test.each(["1.19.5", "2.0.0-beta.1", "invalid", undefined])("both modes reject unsupported version %s", (version) => {
  expect(() => requireOpencodeV2(version)).toThrow("OpenCode 2.0.0 or later is required");
});

// opencode 1.19.x: a bare `upgrade` installs the newest 1.x and only prints
// "OpenCode 2 is available. Upgrade with `opencode upgrade --major`".
test("the refusal names the upgrade that actually reaches OpenCode 2", () => {
  expect(() => requireOpencodeV2("1.19.0")).toThrow("Run opencode upgrade --major and retry.");
});

// 2.2.6's `upgrade` takes only `[target]` and `--method`, and 2.x rejects an
// unknown flag, so `--major` is for the 1.x line alone.
test("the in-app update takes a 1.x install to OpenCode 2 and keeps 2.x on its own updater", () => {
  expect(opencodeUpgradeArgs("1.19.0")).toEqual(["upgrade", "--major"]);
  expect(opencodeUpgradeArgs("2.2.6")).toEqual(["upgrade"]);
  expect(opencodeUpgradeArgs(null)).toEqual(["upgrade"]);
});

test("an owned server exit fails an active V2 event subscription", async () => {
  let exit!: (code: number) => void;
  let subscribed!: () => void;
  const subscription = new Promise<void>((resolve) => { subscribed = resolve; });
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch() {
    subscribed();
    return new Response(new ReadableStream({ start(controller) {
      controller.enqueue(new TextEncoder().encode(": connected\n\n"));
    } }), { headers: { "Content-Type": "text/event-stream" } });
  } });
  const { client } = connectOpencode({ url: server.url.href, exited: new Promise((resolve) => { exit = resolve; }), close: async () => { await server.stop(true); } }, "/checkout");
  try {
    const next = client.events()[Symbol.asyncIterator]().next().then(() => undefined, (error: unknown) => error);
    await subscription;
    exit(1);
    expect(await next).toBeInstanceOf(Error);
  } finally { await client.dispose(); }
});

test("terminal launch checks the native binary before preparing a private V2 session", async () => {
  const directory = mkdtempSync(join(tmpdir(), "opencode-v2-terminal-"));
  const scope = createAgentRunScope({ runId: "version", isCurrent: () => true, emit() {} });
  const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
  const host: AgentHostServices = { logger, stateDirectory: () => "unused", hookCommand: () => ({ binary: "unused", preargs: [] }), killChildTree: async () => {}, stripInheritedCertOverrides: (env) => env };
  const request = { configured: { name: "opencode", command: "my-opencode", args: ["--log-level", "warn"] },
    cwd: process.cwd(), storeDir: directory, signal: scope.signal, scope, approvalPolicy: "default" as const, conversation: { kind: "fresh" as const } };
  try {
    await expect(prepareOpencodeTerminal(request, async () => "1.19.5")).rejects.toThrow("opencode upgrade");
    const launch = await withAgentHost(host, () => prepareOpencodeTerminal(request, async (command) => {
      expect(command).toBe("my-opencode"); return "2.2.5";
    }));
    expect(launch.command).toBe("my-opencode");
    expect(launch.args).toEqual(["--standalone", "--log-level", "warn"]);
  } finally { await scope.dispose(); rmSync(directory, { recursive: true, force: true }); }
});

test("terminal version probing handles native output and Windows command shims", async () => {
  const directory = mkdtempSync(join(tmpdir(), "opencode version & fixture-"));
  const scope = createAgentRunScope({ runId: "probe", isCurrent: () => true, emit() {} });
  const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
  const host: AgentHostServices = { logger, stateDirectory: () => directory, hookCommand: () => ({ binary: "unused", preargs: [] }), killChildTree: async (child) => { child.kill(); }, stripInheritedCertOverrides: (env) => env };
  try {
    for (const version of ["1.19.5", "2.2.5"]) {
      const command = join(directory, process.platform === "win32" ? `opencode-${version}.cmd` : `opencode-${version}`);
      writeFileSync(command, process.platform === "win32" ? `@echo off\r\necho opencode v${version}\r\n` : `#!/bin/sh\nprintf 'opencode v${version}\\n'\n`, { mode: 0o700 });
      const launch = withAgentHost(host, () => prepareOpencodeTerminal({ configured: { name: "opencode", command }, cwd: directory, storeDir: directory,
        approvalPolicy: "default", conversation: { kind: "fresh" }, scope, signal: scope.signal }));
      if (version.startsWith("1.")) await expect(launch).rejects.toThrow("found 1.19.5");
      else expect((await launch).args).toContain("--standalone");
    }
  } finally { await scope.dispose(); rmSync(directory, { recursive: true, force: true }); }
});

test("V2 store reads streamed parts in native order and redacts provider internals for handoff", () => {
  const db = new Database(":memory:");
  try {
    db.exec("CREATE TABLE session_v2 (id TEXT, parent_id TEXT, time_created INTEGER, title TEXT); CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, seq INTEGER, data TEXT); CREATE TABLE session_part (session_id TEXT, message_id TEXT, ordinal INTEGER, data TEXT)");
    db.run("INSERT INTO session_v2 VALUES (?, NULL, 1, ?)", ["root", "title"]);
    const insert = (id: string, type: string, seq: number, data: object) => db.run("INSERT INTO session_message VALUES (?, 'root', ?, ?, ?)", [id, type, seq, JSON.stringify(data)]);
    insert("user", "user", 1, { time: { created: 1 }, text: "question" });
    insert("answer", "assistant", 2, { time: { created: 2 }, model, agent: "build", content: [] });
    db.run("INSERT INTO session_part VALUES ('root', 'answer', 0, ?)", [JSON.stringify({ type: "text", text: "answer", native: { secret: "SECRET-NATIVE" } })]);
    db.run("INSERT INTO session_part VALUES ('root', 'answer', 1, ?)", [JSON.stringify({ type: "tool", id: "tool", name: "antgrid_call", time: { created: 2 }, state: { status: "error", input: {}, error: { type: "APIError", message: "failed", response: { body: "SECRET-BODY" } } } })]);
    expect(readOpencodeV2Messages(db, "root").map((message) => message.id)).toEqual(["user", "answer"]);
    const serialized = serializeOpencodeSession(db, "root", { includeKiloBoard: false })!;
    expect(serialized.doc.messages[1]?.parts[0]?.text).toBe("answer");
    expect(JSON.stringify(serialized)).not.toContain("SECRET-");
    expect(serialized.doc.messages[1]?.parts[1]?.state).toMatchObject({ error: { name: "APIError", data: { message: "failed" } } });
  } finally { db.close(); }
});

// OpenCode 2.2.6-2.3.0 rows: a completed compaction names in metadata.keepID the
// oldest message it kept verbatim, and OpenCode still sends the model the kept
// turns from keepID up to the compaction, not only the summary and later turns.
// Field sets as the native store writes them; the content is invented.
test("the V2 reader keeps the turns a compaction retained", () => {
  const directory = mkdtempSync(join(tmpdir(), "opencode-v2-keep-"));
  const path = join(directory, "opencode.db");
  const db = new Database(path);
  try {
    db.exec("CREATE TABLE session_v2 (id TEXT, parent_id TEXT, time_created INTEGER, title TEXT); CREATE TABLE session_message (id TEXT, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT)");
    let seq = 0;
    const insert = (session: string, id: string, type: string, data: object) => {
      seq++;
      db.run("INSERT INTO session_message VALUES (?, ?, ?, ?, ?, ?, ?)", [id, session, type, seq, seq, seq, JSON.stringify({ time: { created: seq }, ...data })]);
    };
    const user = (session: string, id: string, text: string) => insert(session, id, "user", { text, files: [], agents: [] });
    const assistant = (session: string, id: string, text: string) => insert(session, id, "assistant", {
      agent: "build", model, cost: 0, finish: "stop", tokens: { input: 1, output: 1, reasoning: 0, cache: { read: 0, write: 0 } },
      content: [{ type: "text", text, native: {} }],
    });
    const compaction = (session: string, id: string, keepID: string) => insert(session, id, "compaction", {
      status: "completed", reason: "auto", model, summary: `summary of ${session}`, metadata: { keepID }, cost: 0, tokens: { input: 1, output: 1 },
    });
    for (const session of ["kept", "unknown"]) {
      db.run("INSERT INTO session_v2 VALUES (?, NULL, 1, ?)", [session, session]);
      user(session, `${session}-old-q`, "summarized question");
      assistant(session, `${session}-old-a`, "summarized answer");
      user(session, `${session}-keep-q`, "kept question");
      assistant(session, `${session}-keep-a`, "kept answer");
      insert(session, `${session}-idle`, "idle", { outcome: "succeeded" });
      compaction(session, `${session}-compaction`, session === "kept" ? `${session}-keep-q` : "msg_missing");
      user(session, `${session}-new-q`, "later question");
      assistant(session, `${session}-new-a`, "later answer");
    }
    // A kept tail longer than the reader's row window.
    db.run("INSERT INTO session_v2 VALUES ('long', NULL, 1, 'long')");
    user("long", "long-keep", "first kept question");
    for (let i = 0; i < 250; i++) assistant("long", `long-a${i}`, `kept answer ${i}`);
    compaction("long", "long-compaction", "long-keep");
    user("long", "long-new", "later question");
    db.close();

    expect(readLastOpencodeMessages("kept", 10, path))
      .toEqual(["kept question", "kept answer", "summary of kept", "later question", "later answer"]);
    expect(readLastOpencodeMessages("unknown", 10, path)).toEqual(["summary of unknown", "later question", "later answer"]);
    expect(readLastOpencodeMessages("long", 3, path)).toEqual(["kept answer 249", "summary of long", "later question"]);
    expect(readLastOpencodeMessages("long", 300, path)).toHaveLength(200);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
