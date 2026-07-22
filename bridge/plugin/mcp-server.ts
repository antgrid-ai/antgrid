import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { readFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
// Stub: the interactive 'antgrid init' bootstrap lives in the CLI (see Task 22).
// For the MCP antgrid_init action we emit a minimal starter config.
// TODO: headless bootstrap for MCP (no TTY)
function generateDefaultConfig(_targetPath: string): string {
  return [
    "# Antgrid project config",
    "# See https://antgrid.ai for docs",
    "",
    "relayUrl: wss://relay.antgrid.ai",
    "",
    "agent:",
    "  tool: claude-code",
    "",
    "services: []",
    "commands: []",
    "ports: []",
    "",
  ].join("\n");
}


function getApiUrl(): string | null {
  // Prefer the per-core port stamped into the terminal env; fall back to the
  // shared api.port file (single-core / legacy discovery).
  const envPort = process.env.ANTGRID_API_PORT?.trim();
  let port: string | null = null;
  if (envPort) {
    port = envPort;
  } else {
    const portFile = join(process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid"), "api.port");
    if (!existsSync(portFile)) return null;
    port = readFileSync(portFile, "utf8").trim();
  }
  if (!port || isNaN(Number(port))) return null;
  return `http://127.0.0.1:${port}`;
}

type ApiResult = { ok: boolean; status: number; data: any };

async function api(method: "GET" | "POST", path: string, body?: unknown): Promise<ApiResult> {
  const base = getApiUrl();
  if (!base) return { ok: false, status: 0, data: "Antgrid agent is not running. Start it with: cd <project> && bun run dev" };

  try {
    const opts: RequestInit = { method };
    if (body !== undefined) {
      opts.headers = { "Content-Type": "application/json" };
      opts.body = JSON.stringify(body);
    }
    const resp = await fetch(`${base}${path}`, opts);
    const contentType = resp.headers.get("content-type") ?? "";
    const data = contentType.includes("json") ? await resp.json() : await resp.text();
    return { ok: resp.ok, status: resp.status, data };
  } catch {
    return { ok: false, status: 0, data: "Cannot reach Antgrid agent. Is it running?" };
  }
}


const server = new Server(
  { name: "antgrid", version: "0.1.0" },
  { capabilities: { tools: {} } },
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: "antgrid_init",
      description: "Create a antgrid.yaml config file in the current or specified directory. Does not require the Antgrid agent to be running.",
      inputSchema: {
        type: "object" as const,
        properties: {
          path: {
            type: "string",
            description: "Directory path to create antgrid.yaml in (defaults to current working directory)",
          },
        },
        required: [],
      },
    },
    {
      name: "antgrid_list_commands",
      description: "List available commands defined in the project's antgrid.yaml configuration.",
      inputSchema: {
        type: "object" as const,
        properties: {},
        required: [],
      },
    },
    {
      name: "antgrid_run_command",
      description: "Run a named command defined in antgrid.yaml. Returns the command output and exit code.",
      inputSchema: {
        type: "object" as const,
        properties: {
          name: {
            type: "string",
            description: "Name of the command to run (as defined in antgrid.yaml)",
          },
          confirmed: {
            type: "boolean",
            description: "Set to true to run commands that require confirmation (confirm: true in antgrid.yaml). Default: false.",
          },
        },
        required: ["name"],
      },
    },
    {
      name: "antgrid_list_terminals",
      description: "List active terminals managed by the Antgrid agent. By default excludes 'agent' type terminals (interactive shells).",
      inputSchema: {
        type: "object" as const,
        properties: {
          includeAgent: {
            type: "boolean",
            description: "Include agent-type terminals (interactive shells). Default: false.",
          },
        },
        required: [],
      },
    },
    {
      name: "antgrid_read_terminal",
      description: "Read the recent output (scrollback buffer) from a specific terminal.",
      inputSchema: {
        type: "object" as const,
        properties: {
          terminalId: {
            type: "string",
            description: "ID of the terminal to read from (use antgrid_list_terminals to find IDs)",
          },
        },
        required: ["terminalId"],
      },
    },
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  switch (name) {
    case "antgrid_init": {
      const targetPath = (args?.path as string) ?? process.cwd();
      const configPath = join(targetPath, "antgrid.yaml");

      if (existsSync(configPath)) {
        return {
          content: [{ type: "text", text: `antgrid.yaml already exists at ${configPath}` }],
        };
      }

      const yaml = generateDefaultConfig(targetPath);
      writeFileSync(configPath, yaml, "utf8");
      return {
        content: [{ type: "text", text: `Created ${configPath}\n\n${yaml}` }],
      };
    }

    case "antgrid_list_commands": {
      const result = await api("GET", "/config");
      if (!result.ok) {
        return { content: [{ type: "text", text: String(result.data) }], isError: true };
      }
      const commands = result.data.commands ?? [];
      if (commands.length === 0) {
        return { content: [{ type: "text", text: "No commands defined in antgrid.yaml" }] };
      }
      const lines = commands.map((c: any) =>
        `- ${c.name}${c.confirm ? " (requires confirmation)" : ""}${c.command ? `: ${c.command}` : ""}`
      );
      return { content: [{ type: "text", text: `Commands:\n${lines.join("\n")}` }] };
    }

    case "antgrid_run_command": {
      const cmdName = args?.name as string;
      if (!cmdName) {
        return { content: [{ type: "text", text: "Missing required argument: name" }], isError: true };
      }
      const confirmed = (args?.confirmed as boolean) ?? false;
      const result = await api("POST", `/commands/${encodeURIComponent(cmdName)}/run`, { confirmed });
      if (!result.ok) {
        return { content: [{ type: "text", text: String(result.data?.error ?? result.data) }], isError: true };
      }
      const { exitCode, output } = result.data;
      return {
        content: [{ type: "text", text: `Exit code: ${exitCode}\n\n${output}` }],
      };
    }

    case "antgrid_list_terminals": {
      const includeAgent = (args?.includeAgent as boolean) ?? false;
      const result = await api("GET", `/terminals?all=${includeAgent}`);
      if (!result.ok) {
        return { content: [{ type: "text", text: String(result.data) }], isError: true };
      }
      const terminals = result.data;
      if (terminals.length === 0) {
        return { content: [{ type: "text", text: "No active terminals" }] };
      }
      const lines = terminals.map((t: any) =>
        `- ${t.terminalId} (${t.name}) [${t.running ? "running" : "stopped"}] type=${t.type ?? "unknown"}`
      );
      return { content: [{ type: "text", text: `Terminals:\n${lines.join("\n")}` }] };
    }

    case "antgrid_read_terminal": {
      const terminalId = args?.terminalId as string;
      if (!terminalId) {
        return { content: [{ type: "text", text: "Missing required argument: terminalId" }], isError: true };
      }
      const result = await api("GET", `/terminals/${encodeURIComponent(terminalId)}/scrollback`);
      if (!result.ok) {
        return { content: [{ type: "text", text: String(result.data?.error ?? result.data) }], isError: true };
      }
      const scrollback = String(result.data);
      if (!scrollback) {
        return { content: [{ type: "text", text: "(empty — no output yet)" }] };
      }
      return { content: [{ type: "text", text: scrollback }] };
    }

    default:
      return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
  }
});

const transport = new StdioServerTransport();
await server.connect(transport);
