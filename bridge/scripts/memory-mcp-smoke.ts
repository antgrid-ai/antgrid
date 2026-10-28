import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { MemoryService, type MemoryContext } from "antgrid-memory";

const binary = process.argv[2];
if (!binary) throw new Error("Usage: memory-mcp-smoke <compiled-antgrid-bridge>");
const directory = mkdtempSync(join(tmpdir(), "antgrid-memory-smoke-"));
let memory = new MemoryService({ directory });
const owner = memory.ownerId;
const agent = (): MemoryContext => ({ owner_id: memory.ownerId, actor: "agent", project_id: "non-git-project", session_id: "durable-session", checkout_id: "main", run_id: "live-run", agent_id: "smoke" });
const app = (): MemoryContext => ({ owner_id: memory.ownerId, actor: "app" });
const clients: Client[] = [];
const server = Bun.serve({
  hostname: "127.0.0.1", port: 0,
  async fetch(request) {
    const url = new URL(request.url);
    const body = await request.json() as Record<string, unknown>;
    if (body.runId !== "live-run" || url.searchParams.get("terminalId") !== "durable-session") {
      return Response.json({ error: { code: "NOT_A_SESSION", message: "Invalid smoke caller" } }, { status: 403 });
    }
    const { runId: _, ...params } = body;
    try {
      return Response.json(await memory.execute(agent, { ...params, op: url.pathname.slice("/memory/".length) }, { maxAttempts: 1 }));
    } catch (error) {
      const failure = error as Error & { code?: string };
      return Response.json({ error: { code: failure.code ?? "UNAVAILABLE", message: failure.message } }, { status: 400 });
    }
  },
});

async function connect() {
  const client = new Client({ name: "antgrid-memory-smoke", version: "1.0.0" });
  clients.push(client);
  const env = Object.fromEntries(Object.entries(process.env).filter((entry): entry is [string, string] => entry[1] !== undefined));
  await client.connect(new StdioClientTransport({
    command: binary!, args: ["memory-mcp"], stderr: "pipe",
    env: { ...env, ANTGRID_API_PORT: String(server.port), ANTGRID_TERMINAL_ID: "durable-session", ANTGRID_RUN_ID: "live-run" },
  }));
  return client;
}

async function call(client: Client, name: string, args: Record<string, unknown>) {
  const result = await client.callTool({ name, arguments: args });
  const content = result.content as { type: string; text?: string }[];
  const payload = JSON.parse(content[0]?.text ?? "null") as Record<string, unknown>;
  if (result.isError) throw new Error(JSON.stringify(payload));
  return payload;
}

function assert(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }

try {
  await memory.execute(app, { op: "settings", enabled: true });
  let client = await connect();
  const names = (await client.listTools()).tools.map(tool => tool.name).sort();
  assert(JSON.stringify(names) === JSON.stringify(["memory_forget", "memory_get", "memory_save", "memory_search"]), "Separate memory tool table");
  assert(client.getInstructions()?.includes("automatically save"), "Automatic save instructions");
  const finding = { content: "Smoke persistence sentinel for unicode61 mémoire", memory_type: "observation", scope: "project", applicability: "Observed in an isolated non-Git qualification fixture." };
  const saved = await call(client, "memory_save", finding);
  const duplicate = await call(client, "memory_save", finding);
  assert(saved.id === duplicate.id && duplicate.outcome === "already_present", "Exact duplicate suppression");
  await client.close();
  memory.close();
  memory = new MemoryService({ directory });
  assert(memory.ownerId === owner, "Local profile ownership survives restart");
  client = await connect();
  const found = await call(client, "memory_search", { query: '"persistence sentinel" mémoire' });
  assert((found.results as { id: string }[]).some(record => record.id === saved.id), "Compiled FTS5 and persistence");
  const corrected = await call(client, "memory_save", { ...finding, content: "Corrected smoke persistence sentinel", supersedes: saved.id });
  assert(corrected.id !== saved.id, "Correction creates a revision");
  await call(client, "memory_forget", { id: corrected.id });
  const replay = await memory.execute(agent, { op: "save", operation_key: duplicate.operation_key, save: finding }).then(() => false, () => true);
  assert(replay, "Forgotten duplicate operation stays suppressed");
  const empty = await call(client, "memory_search", { query: "sentinel" });
  assert((empty.results as unknown[]).length === 0, "Forgotten history leaves FTS5");
  console.log(JSON.stringify({ platform: process.platform, runtime: Bun.version, sqlite_fts5: "passed", memory_mcp: "passed", restart: "passed", duplicate_correction_forget_replay: "passed" }));
} finally {
  await Promise.allSettled(clients.map(client => client.close()));
  server.stop(true);
  memory.close();
  rmSync(directory, { recursive: true, force: true });
}
