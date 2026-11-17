import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { MEMORY_SERVER_INSTRUCTIONS } from "antgrid-agents/memory-guidance";
import { MemoryService, type MemoryContext } from "antgrid-memory";
import { resolveMemoryMcpCommand } from "../src/hook-command";

const binary = process.argv[2];
if (!binary) throw new Error("Usage: memory-mcp-smoke <compiled-antgrid-bridge>");
// The argv an agent launch registers for a shipped bridge, not a hand-written one.
const memoryCommand = resolveMemoryMcpCommand({ binary, compiled: true });
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
    command: memoryCommand.binary, args: [...memoryCommand.preargs], stderr: "pipe",
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
  assert(client.getInstructions() === MEMORY_SERVER_INSTRUCTIONS, "Compiled server ships the current Memory instructions");
  const prefix = "Smoke persistence sentinel for unicode61 mémoire ";
  const remaining = 16 * 1024 - Buffer.byteLength(prefix);
  const finding = {
    title: "Archive smoke label", description: "Concise retrieval metadata for an isolated qualification finding.",
    content: prefix + "文".repeat(Math.floor(remaining / 3)) + "a".repeat(remaining % 3),
    memory_type: "observation", scope: "project", applicability: "Observed in an isolated non-Git qualification fixture.",
  };
  const saved = await call(client, "memory_save", finding);
  const duplicate = await call(client, "memory_save", finding);
  assert(saved.id === duplicate.id && duplicate.outcome === "already_present", "Exact duplicate suppression");
  const oversized = await client.callTool({ name: "memory_save", arguments: { ...finding, content: finding.content + "a" } });
  assert(oversized.isError, "Compiled client enforces the shared UTF-8 body limit");
  await client.close();
  memory.close();
  memory = new MemoryService({ directory });
  assert(memory.ownerId === owner, "Local profile ownership survives restart");
  client = await connect();
  const found = await call(client, "memory_search", { query: '"persistence sentinel" mémoire' });
  assert((found.results as { id: string }[]).some(record => record.id === saved.id), "Compiled FTS5 and persistence");
  const labeled = await call(client, "memory_search", { query: '"Archive smoke label"' });
  assert((labeled.results as Record<string, unknown>[]).some(record => record.id === saved.id && record.title === finding.title && record.description === finding.description), "Metadata is searchable and preserved in results");
  const restored = (await call(client, "memory_get", { id: saved.id })).record as Record<string, unknown>;
  assert(restored.content === finding.content && restored.title === finding.title && restored.description === finding.description, "Full 16 KiB body and metadata survive restart");
  const corrected = await call(client, "memory_save", { ...finding, title: "Corrected archive label", description: "Updated qualification finding.", content: "Corrected smoke persistence sentinel", supersedes: saved.id });
  assert(corrected.id !== saved.id, "Correction creates a revision");
  const revision = (await call(client, "memory_get", { id: corrected.id })).record as Record<string, unknown>;
  assert(revision.title === "Corrected archive label" && revision.description === "Updated qualification finding.", "Correction replaces metadata");
  const cleared = await call(client, "memory_save", { content: "Smoke persistence sentinel with cleared labels", memory_type: finding.memory_type, scope: finding.scope, supersedes: corrected.id });
  const unlabeled = (await call(client, "memory_get", { id: cleared.id })).record as Record<string, unknown>;
  assert(unlabeled.title === undefined && unlabeled.description === undefined, "Omitted correction metadata clears the prior labels");
  await call(client, "memory_forget", { id: cleared.id });
  const replay = await memory.execute(agent, { op: "save", operation_key: duplicate.operation_key, save: finding }).then(() => false, () => true);
  assert(replay, "Forgotten duplicate operation stays suppressed");
  const empty = await call(client, "memory_search", { query: "sentinel" });
  assert((empty.results as unknown[]).length === 0, "Forgotten history leaves FTS5");
  console.log(JSON.stringify({ platform: process.platform, runtime: Bun.version, sqlite_fts5: "passed", memory_mcp: "passed", restart: "passed", duplicate_correction_forget_replay: "passed", metadata_body_limits: "passed", correction_metadata: "passed" }));
} finally {
  await Promise.allSettled(clients.map(client => client.close()));
  server.stop(true);
  memory.close();
  rmSync(directory, { recursive: true, force: true });
}
