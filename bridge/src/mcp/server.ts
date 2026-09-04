import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Stub: the interactive 'antgrid init' bootstrap lives in the CLI.
// For the MCP antgrid_init action we emit a minimal starter config.
// TODO(bridge): headless bootstrap for MCP (no TTY)
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

/**
 * The loopback API of the core that spawned us, named ONLY by the per-core port
 * the bridge stamps into every PTY (`ANTGRID_API_PORT`), inherited one hop by
 * whatever the agent spawns.
 *
 * There is deliberately no `api.port` file fallback. That file names the
 * most-recently-started core, the loopback API is unauthenticated, and
 * `antgrid_run_command` executes `antgrid.yaml` commands — so a fallback would
 * hand command execution to any local process able to spell `antgrid-bridge
 * mcp`. The hook path bounds the same hazard per agent
 * (`HookProfile.portFileFallback`) because `bridge hook <name> <event>` names
 * its agent; nothing in this invocation says who spawned it, so the equivalent
 * opt-in cannot be expressed here and absence is the only safe answer.
 *
 * The numeric guard is load-bearing beyond a typo: an injected entry declares
 * the value as `${ANTGRID_API_PORT}`, and an agent that never expands it
 * delivers that literal, which must read as "absent" rather than as a host.
 */
export function getApiUrl(): string | null {
  const port = process.env.ANTGRID_API_PORT?.trim();
  if (!port || isNaN(Number(port))) return null;
  return `http://127.0.0.1:${port}`;
}

/**
 * The slot the agent that spawned us runs in, stamped into every PTY as
 * `ANTGRID_TERMINAL_ID` and inherited one hop. It is what the loopback API
 * resolves the caller's CHECKOUT from: an isolated session runs in a managed
 * worktree while its core's API is shared with main, so without it a tool call
 * answers out of the wrong tree.
 *
 * Same unexpanded-`${…}` hazard as the port, and the same reading: a variable
 * reference that arrived verbatim names no terminal.
 */
export function getTerminalId(): string | undefined {
  const id = process.env.ANTGRID_TERMINAL_ID?.trim();
  if (!id || id.startsWith("${")) return undefined;
  return id;
}

type ApiResult = { ok: boolean; status: number; data: any };

async function api(method: "GET" | "POST", path: string, body?: unknown): Promise<ApiResult> {
  const base = getApiUrl();
  if (!base) {
    return {
      ok: false,
      status: 0,
      data: "Antgrid agent is not running. This server only works inside a session Antgrid started, which stamps its core's API port into the environment.",
    };
  }

  try {
    const opts: RequestInit = { method };
    if (body !== undefined) {
      opts.headers = { "Content-Type": "application/json" };
      opts.body = JSON.stringify(body);
    }
    // Every request names its caller, so the core can answer checkout-scoped
    // routes out of this session's own checkout.
    const url = new URL(`${base}${path}`);
    const terminalId = getTerminalId();
    if (terminalId) url.searchParams.set("terminalId", terminalId);
    const resp = await fetch(url, opts);
    const contentType = resp.headers.get("content-type") ?? "";
    const data = contentType.includes("json") ? await resp.json() : await resp.text();
    return { ok: resp.ok, status: resp.status, data };
  } catch {
    return { ok: false, status: 0, data: "Cannot reach Antgrid agent. Is it running?" };
  }
}

/**
 * Built per process rather than as a module-level singleton: an agent may run
 * several MCP servers for one invocation (two spawns per `claude -p` run,
 * measured), so nothing here may assume one server per terminal.
 */
export function createAntgridMcpServer(): Server {
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

  return server;
}

/** Serve until the agent closes stdin. Resolves when the transport does. */
export async function runMcpStdioServer(): Promise<void> {
  const server = createAntgridMcpServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
