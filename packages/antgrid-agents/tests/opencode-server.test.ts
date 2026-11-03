import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { withAgentHost, type AgentHostServices, type AgentLogger } from "../src/host";
import { OpencodeStartupError, OpencodeStartupCancelledError, startOpencodeServer } from "../src/agents/opencode/server";
import { spawnOpencode } from "../src/agents/opencode/spawn";

const log: AgentLogger = { child: () => log, debug() {}, info() {}, warn() {}, error() {} };
let kills = 0;
const host: AgentHostServices = {
  logger: log, stateDirectory: () => "unused", hookCommand: () => ({ binary: "unused", preargs: [] }),
  stripInheritedCertOverrides: (env) => env,
  killChildTree: async (child) => { kills++; child.kill(); },
};
let directory: string;
let fixture: string;
beforeAll(() => {
  directory = mkdtempSync(join(tmpdir(), "antgrid-opencode-server-"));
  fixture = join(directory, "server.ts");
  writeFileSync(fixture, `
    if (process.env.TEST_SERVER_MODE === "exit") {
      console.error("invalid native configuration"); process.exit(7);
    }
    if (process.env.TEST_SERVER_MODE === "hang") {
      setInterval(() => {}, 1000);
    } else {
      const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: (request) => {
        if (process.env.OPENCODE_PASSWORD) {
          const expected = "Basic " + Buffer.from("opencode:" + process.env.OPENCODE_PASSWORD).toString("base64");
          if (request.headers.get("Authorization") !== expected) return new Response("Unauthorized", { status: 401 });
        }
        if (new URL(request.url).pathname === "/api/info") {
          if (process.env.TEST_SERVER_MODE === "health-hang") return new Promise(() => {});
          return Response.json({ version: process.env.TEST_SERVER_VERSION || "2.2.5" });
        }
        if (new URL(request.url).pathname === "/api/session") return Response.json({ data: { id: "native-session" } });
        return Response.json({
        cwd: process.cwd(), config: process.env.OPENCODE_CONFIG_CONTENT,
        configFile: process.env.OPENCODE_CONFIG, slot: process.env.ANTGRID_TERMINAL_ID,
        run: process.env.ANTGRID_RUN_ID, args: process.argv.slice(2),
      }); } });
      console.log("server listening on http://127.0.0.1:" + server.port);
    }
  `);
});
afterAll(() => rmSync(directory, { recursive: true, force: true }));
const start = (env: Record<string, string>, extra: { timeoutMs?: number; signal?: AbortSignal } = {}) =>
  withAgentHost(host, () => startOpencodeServer({
    cwd: directory, command: process.execPath, prefixArgs: [fixture], env, ...extra,
  }));

test("OpenCode keeps native config and checkout cwd isolated across concurrent chats", async () => {
  const original = process.env.OPENCODE_CONFIG_CONTENT;
  const config = JSON.stringify({ model: "custom/model", mcp: { existing: { type: "remote", url: "https://example.com/mcp" } } });
  const servers = await Promise.all([
    start({ OPENCODE_CONFIG_CONTENT: config, OPENCODE_CONFIG: "custom.json", ANTGRID_TERMINAL_ID: "a", ANTGRID_RUN_ID: "run-a" }),
    start({ OPENCODE_CONFIG_CONTENT: '{"model":"second/model"}', ANTGRID_TERMINAL_ID: "b" }),
  ]);
  try {
    const [a, b] = await Promise.all(servers.map(async (server) => (await fetch(server.url, { headers: server.headers })).json() as Promise<any>));
    expect(a.cwd.toLowerCase()).toBe(directory.toLowerCase());
    expect(a.config).toBe(config);
    expect(a.configFile).toBe("custom.json");
    expect(a.slot).toBe("a");
    expect(a.run).toBe("run-a");
    expect(a.args).toEqual(["serve", "--hostname", "127.0.0.1", "--port", "0"]);
    expect(b.slot).toBe("b");
    expect(JSON.parse(b.config).model).toBe("second/model");
    expect(process.env.OPENCODE_CONFIG_CONTENT).toBe(original);
  } finally {
    await withAgentHost(host, () => Promise.all(servers.map((server) => server.close())));
  }
  await withAgentHost(host, () => servers[0]!.close());
  await expect(fetch(servers[0]!.url)).rejects.toThrow();
});

test("OpenCode reports native startup errors and reaps failed processes", async () => {
  const before = kills;
  await expect(start({ TEST_SERVER_MODE: "exit" })).rejects.toThrow("invalid native configuration");
  expect(kills).toBe(before + 1);
});

test("a missing OpenCode binary is a released acquisition failure", async () => {
  await expect(withAgentHost(host, () => startOpencodeServer({ cwd: directory, command: join(directory, "missing-opencode") })))
    .rejects.toBeInstanceOf(OpencodeStartupError);
});

test("OpenCode client honors native server authentication", async () => {
  await withAgentHost(host, async () => {
    const { client } = await spawnOpencode({ cwd: directory, command: process.execPath, prefixArgs: [fixture],
      env: { OPENCODE_SERVER_USERNAME: "custom-user", OPENCODE_SERVER_PASSWORD: "test-password" },
    });
    try { expect(await client.createSession({})).toBe("native-session"); }
    finally { await client.dispose(); }
  });
});

test("OpenCode times out and reaps a server that never announces readiness", async () => {
  const before = kills;
  await expect(start({ TEST_SERVER_MODE: "hang" }, { timeoutMs: 100 })).rejects.toThrow("startup timed out");
  expect(kills).toBe(before + 1);
});

test("OpenCode cancellation interrupts and reaps an in-flight startup", async () => {
  const abort = new AbortController();
  const before = kills;
  const result = start({ TEST_SERVER_MODE: "hang" }, { signal: abort.signal });
  abort.abort();
  await expect(result).rejects.toBeInstanceOf(OpencodeStartupCancelledError);
  expect(kills).toBe(before + 1);
});

test("OpenCode reports an already-cancelled acquisition without allocating a process", async () => {
  const before = kills;
  await expect(start({ TEST_SERVER_MODE: "hang" }, { signal: AbortSignal.abort() }))
    .rejects.toBeInstanceOf(OpencodeStartupCancelledError);
  expect(kills).toBe(before);
});

test.each(["1.19.5", "2.0.0-beta.1", "unknown"])("OpenCode rejects an unsupported runtime (%s) and releases it", async (version) => {
  const before = kills;
  await expect(start({ TEST_SERVER_VERSION: version })).rejects.toThrow("OpenCode 2.0.0 or later is required");
  expect(kills).toBe(before + 1);
});

test("OpenCode bounds version verification by the startup deadline", async () => {
  const before = kills;
  await expect(start({ TEST_SERVER_MODE: "health-hang" }, { timeoutMs: 600 })).rejects.toThrow("startup timed out");
  expect(kills).toBe(before + 1);
});
