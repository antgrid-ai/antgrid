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

// -- session bus (spec 4.5) -------------------------------------------------
//
// The tool list is ROLE-SHAPED: a lead sees the tools that hand work out, a peer
// the ones that report on it, and a terminal in no multi-machine session sees
// neither. Both halves are the point — offering a peer `antgrid_assign_task`
// buys a call the bridge then refuses, and a tool the agent must not use is
// better absent than present-and-refusing.
//
// The role is asked of the BRIDGE and never derived here: this process knows
// only its terminal id, and which session that terminal belongs to is a fact the
// session manager owns and can change while the agent runs. Every tool below is
// one HTTP call to the route that already made the decision — no cap, no
// membership test and no state transition is evaluated in this process, which is
// the thing those bounds exist to bound.

interface McpTool {
  name: string;
  description: string;
  inputSchema: {
    type: "object";
    properties: Record<string, unknown>;
    required: string[];
  };
}

function str(description: string) {
  return { type: "string", description };
}

function strArray(description: string) {
  return { type: "array", items: { type: "string" }, description };
}

/** The artifact-id parameter, shared by every verb that can attach evidence.
 *  Ids come from `antgrid_publish_artifact`; an id this session did not publish
 *  is refused rather than dropped, so a report never travels having quietly lost
 *  what it was pointing at. */
const ARTIFACT_IDS = strArray(
  "Ids of artifacts this session published, attached to the message as handles.",
);

/** Free text for anything the sender met that the other side did not ask about.
 *  Named rather than folded into the body so it renders under its own heading:
 *  the surprise is the part a lead most needs to read. */
const UNEXPECTED = str("Anything encountered that the instruction did not anticipate.");

const LEAD_TOOLS: McpTool[] = [
  {
    name: "antgrid_list_peers",
    description: "List the peer sessions of this multi-machine session: which machine each runs on, what that machine's bridge observed about it (its OS and its repository), whether it is still active, and whether a message could leave this bridge for it right now.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_assign_task",
    description: "Give a peer session a unit of work. Returns the task id; the peer's result arrives back in this session as a message, so do not poll for it.",
    inputSchema: {
      type: "object",
      properties: {
        peer: str("The peer's session id, as printed by antgrid_list_peers."),
        summary: str("One line naming the work, shown wherever the task is listed."),
        instruction: str("What the peer should do, in full. It cannot see this session's conversation."),
        artifactIds: ARTIFACT_IDS,
        unexpected: UNEXPECTED,
      },
      required: ["peer", "summary", "instruction"],
    },
  },
  {
    name: "antgrid_list_tasks",
    description: "List the tasks of this session: the ones this session assigned, and the ones it was given.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_get_task",
    description: "Read one task in full: its state, its findings so far, and the artifacts attached to it.",
    inputSchema: {
      type: "object",
      properties: { taskId: str("Task id from antgrid_list_tasks.") },
      required: ["taskId"],
    },
  },
  {
    name: "antgrid_cancel_task",
    description: "Withdraw a task already given to a peer. The peer is told to stop; work it already did is not undone.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: str("Task id to withdraw."),
        reason: str("Why it is being withdrawn. The peer is shown this."),
      },
      required: ["taskId", "reason"],
    },
  },
  {
    name: "antgrid_answer_peer",
    description: "Answer a question a peer asked about a task it is working. The peer resumes on receipt.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: str("The task the question was asked about."),
        summary: str("One line naming what is being answered."),
        answer: str("The answer, in full."),
      },
      required: ["taskId", "summary", "answer"],
    },
  },
];

const PEER_TOOLS: McpTool[] = [
  {
    name: "antgrid_get_brief",
    description: "Re-read the brief this session was created with: what it owns, what it must report, and what it may not touch.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_open_task",
    description: "Mark a task as being worked, so the lead can see it started.",
    inputSchema: {
      type: "object",
      properties: { taskId: str("Task id to start work on.") },
      required: ["taskId"],
    },
  },
  {
    name: "antgrid_report_complete",
    description: "Report a task finished. This is what tells the lead the work is done — nothing else does.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: str("Task id being reported on."),
        summary: str("One line saying what was done."),
        text: str("The result in full: what changed, and where."),
        artifactIds: ARTIFACT_IDS,
        unexpected: UNEXPECTED,
      },
      required: ["taskId", "summary"],
    },
  },
  {
    name: "antgrid_report_failure",
    description: "Report a task that cannot be finished, and why. Use this rather than going quiet: the lead is told nothing by an absence.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: str("Task id being reported on."),
        summary: str("One line saying what failed."),
        text: str("What was attempted and what stopped it."),
        artifactIds: ARTIFACT_IDS,
        unexpected: UNEXPECTED,
      },
      required: ["taskId", "summary"],
    },
  },
  {
    name: "antgrid_report_finding",
    description: "Send the lead something worth knowing without ending the task — a discovery, a risk, a decision it should weigh in on.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: str("The task this concerns, when it concerns one."),
        summary: str("One line naming the finding."),
        text: str("The finding in full."),
        unexpected: UNEXPECTED,
      },
      required: ["summary"],
    },
  },
  {
    name: "antgrid_ask_lead",
    description: "Ask the lead a question about a task and wait. The answer arrives in this session as a message; do not poll for it.",
    inputSchema: {
      type: "object",
      properties: {
        taskId: str("The task the question is about."),
        summary: str("One line naming what is being asked."),
        question: str("The question in full, including what you already tried."),
      },
      required: ["taskId", "summary", "question"],
    },
  },
];

const SHARED_TOOLS: McpTool[] = [
  {
    name: "antgrid_publish_artifact",
    description: "Store a file-sized piece of evidence — a diff, a log, a transcript — and get back an id to attach to a task or a report. Content itself does not travel; the other machine fetches it by id.",
    inputSchema: {
      type: "object",
      properties: {
        name: str("A short file-like name, e.g. build-failure.log."),
        summary: str("One line saying what it is, shown wherever the handle appears."),
        content: str("The text to store. Use contentBase64 instead for anything that is not text."),
        contentBase64: str("Base64 bytes, for content that is not text. Pass exactly one of content or contentBase64."),
        mediaType: str("Media type, defaulting to text/plain."),
        taskId: str("The task this belongs to, when it belongs to one."),
      },
      required: ["name", "summary"],
    },
  },
  {
    name: "antgrid_list_artifacts",
    description: "List the artifacts this session has published.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_get_artifact",
    description: "Read back the content of an artifact this session published, one chunk at a time.",
    inputSchema: {
      type: "object",
      properties: {
        artifactId: str("Artifact id from antgrid_list_artifacts."),
        offset: { type: "number", description: "Byte offset to read from. Default 0." },
        length: { type: "number", description: "Bytes to read, clamped to one chunk." },
      },
      required: ["artifactId"],
    },
  },
  {
    name: "antgrid_session_status",
    description: "Where this session stands in its multi-machine session: its role, its members, its open tasks, and how much of its task budget is left.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
];

const BUS_TOOLS_BY_NAME = new Map(
  [...LEAD_TOOLS, ...PEER_TOOLS, ...SHARED_TOOLS].map((t) => [t.name, t] as const),
);

export interface BusRoleView {
  lead: boolean;
  peer: boolean;
}

/** How long a resolved role is reused. A client re-lists tools far more often
 *  than a session gains or loses members, and a role one list stale costs at
 *  most a refusal the bridge itself authors. `tools/list_changed` is not emitted
 *  yet, so a shorter window buys nothing a call would not already discover. */
export const ROLE_CACHE_MS = 5_000;

/**
 * The caller's role, cached per SERVER rather than per process: an agent may run
 * several servers for one invocation, and a cache outliving the server that made
 * it would answer for a terminal that is no longer the one asking.
 */
export function createBusRoleCache(
  now: () => number = Date.now,
): { get(): Promise<BusRoleView>; refresh(): Promise<BusRoleView> } {
  let cached: { at: number; view: BusRoleView } | null = null;
  const resolve = async (): Promise<BusRoleView> => {
      const at = now();
      const result = await api("GET", "/session-bus/role");
      // An unreachable bridge, a core with no bus, and a terminal in no session
      // are one answer here: no session tools. The failure is cached like a
      // success on purpose — a client listing tools in a loop against a dead
      // port is exactly the traffic this cache exists to stop.
      const data = result.ok && typeof result.data === "object" && result.data !== null
        ? result.data as { lead?: unknown; peer?: unknown }
        : null;
      const view = { lead: data?.lead === true, peer: data?.peer === true };
      cached = { at, view };
      return view;
  };
  return {
    async get() {
      const at = now();
      if (cached && at - cached.at < ROLE_CACHE_MS) return cached.view;
      return resolve();
    },
    // Bypasses the TTL on purpose: the watcher below is the one caller whose
    // whole job is to notice a change, and a cached answer is the one thing it
    // must never be given.
    refresh: resolve,
  };
}

/** How often a connected server re-asks for its role so it can tell the client
 *  the tool list moved. A machine is added by a human pressing a button, so this
 *  is the delay between that press and the lead being able to act on it. */
export const ROLE_WATCH_MS = 5_000;

/** A machine can lead one session and work another, so a role that is both gets
 *  both tables. */
export function sessionBusTools(role: BusRoleView): McpTool[] {
  if (!role.lead && !role.peer) return [];
  return [
    ...(role.lead ? LEAD_TOOLS : []),
    ...(role.peer ? PEER_TOOLS : []),
    ...SHARED_TOOLS,
  ];
}

export function isSessionBusTool(name: string): boolean {
  return BUS_TOOLS_BY_NAME.has(name);
}

type ToolResult = { content: { type: "text"; text: string }[]; isError?: boolean };

function toolText(text: string): ToolResult {
  return { content: [{ type: "text", text }] };
}

function toolError(text: string): ToolResult {
  return { content: [{ type: "text", text }], isError: true };
}

/** A refusal, rendered as the bridge wrote it. The code is appended rather than
 *  translated: it is the one part of the answer an agent can act on
 *  mechanically (retry later, ask a human, stop), and re-wording the sentence
 *  would put this process back in the business of deciding. */
function busError(result: ApiResult): string {
  const data = result.data;
  if (data && typeof data === "object") {
    const error = (data as { error?: unknown }).error;
    const code = (data as { code?: unknown }).code;
    if (typeof error === "string") {
      return typeof code === "string" ? `${error} (${code})` : error;
    }
  }
  return String(data);
}

function argStr(args: Record<string, unknown> | undefined, key: string): string | undefined {
  const v = args?.[key];
  return typeof v === "string" ? v : undefined;
}

function argNum(args: Record<string, unknown> | undefined, key: string): number | undefined {
  const v = args?.[key];
  return typeof v === "number" ? v : undefined;
}

function argIds(args: Record<string, unknown> | undefined, key: string): string[] | undefined {
  const v = args?.[key];
  if (!Array.isArray(v)) return undefined;
  return v.filter((x): x is string => typeof x === "string");
}

/** Drop the keys the caller left unset, so a body reaches a `.strict()` schema
 *  carrying only what was actually said. */
function body(fields: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));
}

function taskLine(t: any): string {
  const waiting = t.waitingOn ? ` waiting on ${t.waitingOn}` : "";
  return `- ${t.taskId} [${t.state}${waiting}] ${t.title}`;
}

function artifactLine(a: any): string {
  return `- ${a.artifactId} ${a.name} (${a.mediaType}, ${a.bytes} bytes): ${a.summary}`;
}

/** One peer, plus whatever its own bridge observed about it (spec 3.3).
 *
 *  The card's two lines are indented under the peer rather than appended to it:
 *  a machine is picked by reading its OS and its repo against the work in hand,
 *  and a single line carrying six values reads as one identifier. A field the
 *  peer's bridge could not answer prints nothing at all — a blank here would
 *  invite the lead to ask about an absence the card never claimed. */
function peerLines(p: any): string[] {
  const unreachable = p.reachable ? "" : " (cannot be reached from here right now)";
  const out = [
    `- ${p.sessionName ?? p.sessionId} [${p.state}]${unreachable}`
    + ` id=${p.sessionId} machine=${p.machineLabel ?? p.machineId}`,
  ];
  const os = [p.card?.os?.name, p.card?.os?.version, p.card?.os?.arch].filter(Boolean);
  if (os.length > 0) out.push(`  os: ${os.join(", ")}`);
  const repo = [p.card?.repo?.label, p.card?.repo?.remote, p.card?.repo?.branch].filter(Boolean);
  if (repo.length > 0) out.push(`  repo: ${repo.join(", ")}`);
  return out;
}

/**
 * Run one session-bus tool. Every branch is the same shape — build a body, call
 * the route, render what came back — because the route is where the decision was
 * made.
 */
export async function callSessionBusTool(
  name: string,
  args: Record<string, unknown> | undefined,
): Promise<ToolResult> {
  const taskId = argStr(args, "taskId");
  const taskPath = taskId ? `/session-bus/tasks/${encodeURIComponent(taskId)}` : null;

  switch (name) {
    case "antgrid_list_peers": {
      const r = await api("GET", "/session-bus/peers");
      if (!r.ok) return toolError(busError(r));
      const peers = (r.data.peers ?? []) as any[];
      if (peers.length === 0) return toolText("No peer sessions have joined this session yet.");
      return toolText(`Peers:\n${peers.flatMap(peerLines).join("\n")}`);
    }

    case "antgrid_assign_task": {
      const r = await api("POST", "/session-bus/tasks", body({
        peer: argStr(args, "peer"),
        summary: argStr(args, "summary"),
        instruction: argStr(args, "instruction"),
        artifactIds: argIds(args, "artifactIds"),
        unexpected: argStr(args, "unexpected"),
      }));
      if (!r.ok) return toolError(busError(r));
      return toolText(`Assigned as task ${r.data.taskId}. The peer's result arrives here as a message.`);
    }

    case "antgrid_list_tasks": {
      const r = await api("GET", "/session-bus/tasks");
      if (!r.ok) return toolError(busError(r));
      const tasks = (r.data.tasks ?? []) as any[];
      if (tasks.length === 0) return toolText("No tasks on this session.");
      return toolText(`Tasks:\n${tasks.map(taskLine).join("\n")}`);
    }

    case "antgrid_get_task": {
      if (!taskPath) return toolError("Missing required argument: taskId");
      const r = await api("GET", taskPath);
      if (!r.ok) return toolError(busError(r));
      return toolText(JSON.stringify(r.data, null, 2));
    }

    case "antgrid_cancel_task": {
      if (!taskPath) return toolError("Missing required argument: taskId");
      const r = await api("POST", `${taskPath}/cancel`, body({ reason: argStr(args, "reason") }));
      if (!r.ok) return toolError(busError(r));
      return toolText(`Task ${taskId} withdrawn. The peer has been told to stop.`);
    }

    case "antgrid_answer_peer": {
      if (!taskPath) return toolError("Missing required argument: taskId");
      const r = await api("POST", `${taskPath}/answer`, body({
        summary: argStr(args, "summary"),
        answer: argStr(args, "answer"),
      }));
      if (!r.ok) return toolError(busError(r));
      return toolText(`Answer sent. The peer resumes task ${taskId} on receipt.`);
    }

    case "antgrid_get_brief": {
      const r = await api("GET", "/session-bus/brief");
      if (!r.ok) return toolError(busError(r));
      const scope = (r.data.scope ?? []) as { label: string; text: string }[];
      const scopeText = scope.length === 0 ? "" : `\n\n${scope.map((s) => `${s.label}: ${s.text}`).join("\n")}`;
      return toolText(`${r.data.brief}${scopeText}`);
    }

    case "antgrid_open_task": {
      if (!taskPath) return toolError("Missing required argument: taskId");
      const r = await api("POST", `${taskPath}/open`);
      if (!r.ok) return toolError(busError(r));
      return toolText(`Task ${taskId} is now marked as being worked.`);
    }

    case "antgrid_report_complete":
    case "antgrid_report_failure": {
      if (!taskPath) return toolError("Missing required argument: taskId");
      const done = name === "antgrid_report_complete";
      const r = await api("POST", `${taskPath}/${done ? "complete" : "fail"}`, body({
        summary: argStr(args, "summary"),
        text: argStr(args, "text"),
        artifactIds: argIds(args, "artifactIds"),
        unexpected: argStr(args, "unexpected"),
      }));
      if (!r.ok) return toolError(busError(r));
      return toolText(`Task ${taskId} reported ${done ? "complete" : "failed"}. The lead has been told.`);
    }

    case "antgrid_report_finding": {
      const r = await api("POST", "/session-bus/findings", body({
        taskId,
        summary: argStr(args, "summary"),
        text: argStr(args, "text"),
        unexpected: argStr(args, "unexpected"),
      }));
      if (!r.ok) return toolError(busError(r));
      return toolText(r.data.sent
        ? "Finding sent to the lead."
        : "Finding recorded on the task. It travels with the next report.");
    }

    case "antgrid_ask_lead": {
      const r = await api("POST", "/session-bus/ask", body({
        taskId,
        summary: argStr(args, "summary"),
        question: argStr(args, "question"),
      }));
      if (!r.ok) return toolError(busError(r));
      return toolText("Question sent to the lead. Its answer arrives here as a message — stop and wait for it rather than polling.");
    }

    case "antgrid_publish_artifact": {
      const r = await api("POST", "/session-bus/artifacts", body({
        name: argStr(args, "name"),
        summary: argStr(args, "summary"),
        content: argStr(args, "content"),
        contentBase64: argStr(args, "contentBase64"),
        mediaType: argStr(args, "mediaType"),
        taskId,
      }));
      if (!r.ok) return toolError(busError(r));
      const a = r.data.artifact;
      return toolText(`Published ${a.name} as ${a.artifactId} (${a.bytes} bytes). Attach that id to a task or a report.`);
    }

    case "antgrid_list_artifacts": {
      const r = await api("GET", "/session-bus/artifacts");
      if (!r.ok) return toolError(busError(r));
      const artifacts = (r.data.artifacts ?? []) as any[];
      if (artifacts.length === 0) return toolText("This session has published no artifacts.");
      return toolText(`Artifacts:\n${artifacts.map(artifactLine).join("\n")}`);
    }

    case "antgrid_get_artifact": {
      const artifactId = argStr(args, "artifactId");
      if (!artifactId) return toolError("Missing required argument: artifactId");
      const query = new URLSearchParams();
      const offset = argNum(args, "offset");
      const length = argNum(args, "length");
      if (offset !== undefined) query.set("offset", String(offset));
      if (length !== undefined) query.set("length", String(length));
      const suffix = query.size > 0 ? `?${query.toString()}` : "";
      const r = await api("GET", `/session-bus/artifacts/${encodeURIComponent(artifactId)}${suffix}`);
      if (!r.ok) return toolError(busError(r));
      const more = r.data.eof ? "" : "\n\n(more follows — read again with a higher offset)";
      return toolText(`${r.data.text}${more}`);
    }

    case "antgrid_session_status": {
      const r = await api("GET", "/session-bus/session");
      if (!r.ok) return toolError(busError(r));
      const d = r.data;
      const members = (d.members ?? []) as any[];
      const budget = d.budget ?? {};
      const lines = [
        `Role: ${d.role ?? "none"}${d.lead && d.peer ? " (leads one session, works another)" : ""}`,
        `Session: ${d.sessionId} in context ${d.contextId}`,
        `Members: ${members.length === 0 ? "none" : members.map((m) => `${m.sessionName ?? m.sessionId} [${m.state}]`).join(", ")}`,
        `Open tasks: ${(d.openTaskIds ?? []).join(", ") || "none"}`,
        `Task budget: ${budget.tasksRemaining} left of the session cap, ${budget.hourlyRemaining} in this hour${budget.halted ? " (halted: no progress)" : ""}`,
      ];
      return toolText(lines.join("\n"));
    }

    default:
      return toolError(`Unknown tool: ${name}`);
  }
}

/** The tools every caller gets, in a session or out of one. */
const BASE_TOOLS: McpTool[] = [
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
];

/**
 * Built per process rather than as a module-level singleton: an agent may run
 * several MCP servers for one invocation (two spawns per `claude -p` run,
 * measured), so nothing here may assume one server per terminal.
 */
export function createAntgridMcpServer(): Server {
  const server = new Server(
    { name: "antgrid", version: "0.1.0" },
    // `listChanged` is not decoration: a client that was not told the list can
    // move has no reason to ever re-list, and this server's list DOES move — a
    // session becomes a lead the moment a human adds a machine to it, long after
    // the client listed tools at connect. Without this the lead is handed a join
    // notice telling it to call tools it was never offered.
    { capabilities: { tools: { listChanged: true } } },
  );

  // Per server, so a second server in the same invocation resolves its own role
  // rather than inheriting one taken for a terminal that is no longer asking.
  const busRole = createBusRoleCache();

  let known: BusRoleView | null = null;
  server.setRequestHandler(ListToolsRequestSchema, async () => {
    // Remembered as "what the client has been told", which is what the watcher
    // below compares against — and taken from here rather than from a probe of
    // its own, so resolving the role costs exactly the requests listing already
    // made.
    const view = await busRole.get();
    known = view;
    return { tools: [...BASE_TOOLS, ...sessionBusTools(view)] };
  });

  // Watch the role for as long as a client is attached. Polled rather than
  // pushed because this process reaches the bridge only over the loopback API;
  // one GET every few seconds against a port on the same machine is cheaper than
  // the socket a push would need, and the timer is unref'd so it can never be
  // what keeps an agent's MCP process alive.
  let watch: ReturnType<typeof setInterval> | null = null;
  server.oninitialized = () => {
    watch = setInterval(() => {
      void busRole.refresh().then((view) => {
        const told = known;
        known = view;
        // A client that never listed is told only when there is something new
        // to list; one that did is told whenever its list would now differ.
        const stale = told === null
          ? view.lead || view.peer
          : view.lead !== told.lead || view.peer !== told.peer;
        if (!stale) return;
        // Fire-and-forget: a notification the transport could not take is a
        // client that is going away anyway, and throwing here would take the
        // timer with it.
        void server.sendToolListChanged().catch(() => {});
      }).catch(() => {});
    }, ROLE_WATCH_MS);
    watch.unref?.();
  };
  const stopWatch = () => {
    if (watch) clearInterval(watch);
    watch = null;
  };
  const priorClose = server.onclose;
  server.onclose = () => {
    stopWatch();
    priorClose?.();
  };

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
        // Dispatched by NAME, not by the role that listed it: a tool called by
        // an agent whose role no longer offers it must reach the bridge and be
        // refused there, with the reason the bridge authored — a local "unknown
        // tool" would report a membership change as a broken server.
        if (isSessionBusTool(name)) return await callSessionBusTool(name, args);
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
