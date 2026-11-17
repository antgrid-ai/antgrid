import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { CallToolRequestSchema, ListToolsRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { MEMORY_SERVER_INSTRUCTIONS } from "antgrid-agents/memory-guidance";
import { MemoryMcpClient } from "./client";

const string = (description: string) => ({ type: "string", description });
const id = string("A memory id from memory_search, memory_get or memory_save.");
export const MEMORY_TOOLS = [
  {
    name: "memory_search",
    description: "Find memories relevant to your current work. Any of the words can match, so use a few distinctive ones such as identifiers, file names or error codes; put a phrase in double quotes to match it exactly. Results come best match first and may be excerpts: read the full record with memory_get before relying on one. You see this project's memories and your own session's task memories.",
    inputSchema: { type: "object", properties: { query: string("Plain text, at most 1 KiB UTF-8. Double quotes mark a phrase; words such as AND, OR and NOT are searched as plain words, and symbols such as * and - only separate words."), limit: { type: "integer", minimum: 1, maximum: 10, default: 5 } }, required: ["query"], additionalProperties: false },
  },
  {
    name: "memory_get",
    description: "Read one memory in full, with its conditions, source and evidence. Set history to true to read an expired or replaced version, for example before correcting it. Forgotten memories are never returned, and history never shows a memory you could not otherwise read.",
    inputSchema: { type: "object", properties: { id, history: { type: "boolean", default: false } }, required: ["id"], additionalProperties: false },
  },
  {
    name: "memory_save",
    description: "Save one finding for later sessions. Search first; do not save a finding that is already stored, even reworded. Supply a concise title and description, and write the content to stand alone: what is true, when it holds and how you know. To correct a memory, read its latest version with memory_get, then save the corrected finding with supersedes set to that version's id. Submit updated title and description with the correction; omitting either clears that field. A finding that holds under different conditions is a separate memory, not a correction. A reply with an id means it is stored. If the outcome is unknown, Antgrid finishes or drops the save itself: do not save the same finding again, and search for it later if it matters. Never include credentials or personal data.",
    inputSchema: {
      type: "object",
      properties: {
        title: string("A concise label for the finding. Optional; at most 256 bytes UTF-8. On a correction, omitting this clears the previous title."),
        description: string("A concise summary that helps another session decide whether to read the finding. Optional; at most 512 bytes UTF-8. On a correction, omitting this clears the previous description."),
        content: string("The finding, written so it makes sense without this conversation. Keep it concise; at most 16 KiB UTF-8."),
        memory_type: {
          type: "string", enum: ["preference", "task_state", "observation", "note"],
          description: "note: a fact, fix or decision about the project. observation: something you saw happen, with the conditions you saw it under. preference: a default the user stated, or a pattern they repeated across distinct tasks; one request in one task is a note, not a preference. task_state: progress on this task, such as open questions, approaches tried and the next step; needs task scope and drops out of recall after 30 days without an update.",
        },
        scope: { type: "string", enum: ["project", "task"], description: "project: any session on this project can read it. task: only this session can read it; use it for this task's progress and for findings that depend on unfinished work. Antgrid fills in the project and session itself." },
        applicability: string("When the finding holds: OS, versions, configuration, and how sure you are. At most 1 KiB UTF-8. Leaving it empty does not mean it holds everywhere."),
        evidence: { type: "array", maxItems: 8, items: string("Where the finding comes from, such as a file path, command, test, commit or URL. Never a credential or a whole transcript.") },
        restrict_to_checkout: { type: "boolean", description: "Set to true for a task finding that depends on unfinished work in this checkout, so it is not read from another checkout." },
        supersedes: string("The id of the latest version of the memory this corrects. A correction cannot widen its scope or checkout restriction."),
      },
      required: ["content", "memory_type", "scope"], additionalProperties: false,
    },
  },
  {
    name: "memory_forget",
    description: "Delete a memory together with its earlier and later versions, and cancel any save of it still pending. It does not change source files, your own agent memory or anything already in a conversation. Works while saving is paused.",
    inputSchema: { type: "object", properties: { id }, required: ["id"], additionalProperties: false },
  },
];

/** `ready` gates every tool call, so startup recovery still precedes any request without delaying the MCP handshake. */
export function createMemoryMcpServer(client = new MemoryMcpClient(), ready: Promise<unknown> = Promise.resolve()): Server {
  const server = new Server({ name: "antgrid-memory", version: "1.0.0" }, {
    capabilities: { tools: {} }, instructions: MEMORY_SERVER_INSTRUCTIONS,
  });
  server.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: MEMORY_TOOLS }));
  server.setRequestHandler(CallToolRequestSchema, async request => {
    await ready.catch(() => {});
    const result = await client.call(request.params.name, request.params.arguments ?? {});
    return { isError: !!result.error, content: [{ type: "text", text: JSON.stringify(result) }] };
  });
  return server;
}

export async function runMemoryMcpStdioServer(): Promise<void> {
  const client = new MemoryMcpClient();
  await createMemoryMcpServer(client, client.recover()).connect(new StdioServerTransport());
}
