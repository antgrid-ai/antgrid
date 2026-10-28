import { expect, test } from "bun:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { createMemoryMcpServer, MEMORY_INSTRUCTIONS } from "./server";
import { MemoryMcpClient } from "./client";
import { searchResponse } from "../../../packages/antgrid-memory/src/search";
import type { MemoryRecord } from "antgrid-memory";

test("memory MCP advertises only its four tools and static guidance", async () => {
  const calls: { op: string; body: Record<string, unknown> }[] = [];
  const server = createMemoryMcpServer(new MemoryMcpClient({ request: async (op, body) => {
    calls.push({ op, body });
    return { error: { code: "NOT_A_SESSION", message: "Caller expired" } };
  } }));
  const client = new Client({ name: "memory-test", version: "1" });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  try {
    await server.connect(serverTransport);
    await client.connect(clientTransport);
    expect((await client.listTools()).tools.map(tool => tool.name)).toEqual(["memory_search", "memory_get", "memory_save", "memory_forget"]);
    expect(client.getInstructions()).toBe(MEMORY_INSTRUCTIONS);
    const result = await client.callTool({ name: "memory_get", arguments: { id: "expired", history: true } });
    expect(result.isError).toBe(true);
    expect(calls).toEqual([{ op: "get", body: { id: "expired", history: true } }]);
    expect(JSON.parse((result.content as { text: string }[])[0]!.text).error.code).toBe("NOT_A_SESSION");
  } finally { await client.close(); await server.close(); }
});

test("search remains within its UTF-8 byte budget after MCP JSON escaping", async () => {
  const records: MemoryRecord[] = Array.from({ length: 11 }, (_, index) => ({
    id: `memory-${index}`, owner_id: "profile", content: '"引用\\\n'.repeat(350),
    applicability: "Only under the original-language fixture conditions.", memory_type: "observation", scope: "project",
    project_id: "project", source: { actor: "agent", project_id: "project", session_id: "session", agent_id: "test" },
    evidence: [], created_at: 0, updated_at: 0, lifecycle: "active",
  }));
  const response = searchResponse(records, 10);
  const encoded = JSON.stringify({ jsonrpc: "2.0", id: 1, result: { isError: false, content: [{ type: "text", text: JSON.stringify(response) }] } });
  expect(Buffer.byteLength(encoded, "utf8")).toBeLessThanOrEqual(8192);
  expect(response.has_more).toBe(true);
  expect(response.results.some(record => record.excerpted)).toBe(true);
  expect(response.results.every(record => record.applicability === records[0]!.applicability)).toBe(true);
});
