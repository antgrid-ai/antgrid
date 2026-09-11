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

// -- session bus -----------------------------------------------------------
//
// One table, offered to every caller. A tool an agent cannot use right now is
// refused by the bridge with the bridge's own reason, which is worth more than
// a tool the agent never sees and therefore never learns exists.
//
// Every tool below is one HTTP call to the route that already made the decision
// — no cap, no membership test and no state transition is evaluated in this
// process, which is the thing those bounds exist to bound.

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

/** Where a send is aimed, spelled exactly as a row of antgrid_list_sessions
 *  spells it. `machineId` is omissible because a directory row on a machine with
 *  no relay identity carries none, and requiring it would leave a local-mode
 *  agent unable to name the session next to it. */
function sendTargetSchema() {
  return {
    type: "object",
    description: "The session to address, copied from a row of antgrid_list_sessions. Optional beside a threadId, which already records the other end.",
    properties: {
      machineId: {
        // A client that validates arguments against this schema before
        // dispatching would reject an explicit null locally, and the refusal
        // would be its own — nothing on this machine would log it, and the
        // route's own handling of null would be unreachable through the only
        // surface that calls it.
        type: ["string", "null"],
        description: "Machine the session runs on. Omit or pass null for a session on this machine.",
      },
      projectId: str("Project the session belongs to."),
      sessionId: str("The session itself."),
    },
    required: ["projectId", "sessionId"],
  };
}

function artifactIdsSchema() {
  return {
    type: "array",
    items: { type: "string" },
    description: "Ids from antgrid_publish_artifact. The other side is shown each id, name and summary and cannot read the bytes, so anything it must READ belongs in text.",
  };
}

/** The tools that reach the bus. Their own table because the dispatch below
 *  routes them by name to the loopback API instead of answering here; what a
 *  client is offered is BASE_TOOLS, which spreads this in. */
export const SESSION_BUS_TOOLS: McpTool[] = [
  {
    name: "antgrid_list_sessions",
    description: "List the other agent sessions you can address — every session, on this machine or a connected one, whose project is the same git repository as yours. Rows are ordered by how likely they are to matter (same branch, then still working, then recently active), not scored: read the titles and judge. The answer always ends with a line saying how far the read actually reached, so an empty list can be told apart from a read that could not ask.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_whoami",
    description: "The address another session must use to reach you, and the title you are listed under. No other tool names you: antgrid_list_sessions lists everyone except you, a delivery names its sender, and a send names the thread it opened. Ask when your address has to travel — you are asking a session to have a third one report back to you, or you are writing down where you can be reached.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_publish_artifact",
    description: "Store a file-sized piece of evidence — a diff, a log, a transcript — and get back an id to name in a message. The bytes stay on this machine. The other side is shown the id, name and summary and cannot read the content, so put anything it must actually READ in the message text.",
    inputSchema: {
      type: "object",
      properties: {
        name: str("A short file-like name, e.g. build-failure.log."),
        summary: str("One line saying what it is, shown wherever the handle appears."),
        content: str("The text to store. Use contentBase64 instead for anything that is not text."),
        contentBase64: str("Base64 bytes, for content that is not text. Pass exactly one of content or contentBase64."),
        mediaType: str("Media type, defaulting to text/plain."),
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
    name: "antgrid_post",
    description: "Leave a message in another session's mailbox. It does not interrupt anything: the other agent reads it when it next chooses to, so this is the verb for anything that is not blocking that session. It is also the unbudgeted one — the mailbox is bounded instead, and its oldest post is dropped when it fills. Address it with a row from antgrid_list_sessions. The answer carries the thread id to continue on.",
    inputSchema: {
      type: "object",
      properties: {
        to: sendTargetSchema(),
        summary: str("One line saying what this message is, shown wherever it is listed."),
        text: str("The message body — what the other agent actually reads."),
        artifactIds: artifactIdsSchema(),
        unexpected: str("Something you found that nobody asked about, kept out of the answer so it reads as a separate claim."),
        threadId: str("Thread id from an earlier message, to answer that exchange without interrupting. Omit to open a new thread — and when you pass one, `to` is optional, because the thread already records who is on the other end."),
      },
      required: ["summary"],
    },
  },
  {
    name: "antgrid_notify",
    description: "Interrupt another session: the message is submitted into it at its next turn boundary, landing in the middle of what that agent is doing. It is rate-limited per peer and refused outright when the target is not running, so it is not the verb to reach for by default — antgrid_post is the unbudgeted one and always reaches. Use this only when the other side cannot usefully continue without knowing.",
    inputSchema: {
      type: "object",
      properties: {
        to: sendTargetSchema(),
        summary: str("One line saying what this message is, shown wherever it is listed."),
        text: str("The message body — what the other agent actually reads."),
        artifactIds: artifactIdsSchema(),
        unexpected: str("Something you found that nobody asked about, kept out of the answer so it reads as a separate claim."),
        threadId: str("Thread id from an earlier message, to interrupt on that exchange. Omit to open a new thread — and when you pass one, `to` is optional, because the thread already records who is on the other end."),
      },
      required: ["summary"],
    },
  },
  {
    name: "antgrid_reply",
    description: "Answer on a thread you were told about, by its id and nothing else — the bridge remembers who is on the other end, so a reply cannot be misaddressed. Interrupts the peer the way antgrid_notify does, and is budgeted the same way.",
    inputSchema: {
      type: "object",
      properties: {
        threadId: str("The thread being answered, as antgrid_inbox or the line that interrupted you spelled it."),
        summary: str("One line saying what this message is, shown wherever it is listed."),
        text: str("The message body — what the other agent actually reads."),
        artifactIds: artifactIdsSchema(),
        unexpected: str("Something you found that nobody asked about, kept out of the answer so it reads as a separate claim."),
      },
      required: ["threadId", "summary"],
    },
  },
  {
    name: "antgrid_inbox",
    description: "Read the posts waiting for this session, and mark them read. Each row names who sent it, the thread to answer on, and any artifacts it points at. The header says how many older posts were dropped unread because the mailbox filled.",
    inputSchema: { type: "object", properties: {}, required: [] },
  },
  {
    name: "antgrid_thread",
    description: "Read one exchange end to end — both directions, oldest first. Each message you sent says whether the other side acknowledged it, which is the only confirmation in this design that anything arrived.",
    inputSchema: {
      type: "object",
      properties: {
        threadId: str("Thread id, from antgrid_inbox or from what a send answered."),
      },
      required: ["threadId"],
    },
  },
];

const BUS_TOOL_NAMES = new Set(SESSION_BUS_TOOLS.map((t) => t.name));

export function isSessionBusTool(name: string): boolean {
  return BUS_TOOL_NAMES.has(name);
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

/** Drop the keys the caller left unset, so a body reaches a `.strict()` schema
 *  carrying only what was actually said. */
function body(fields: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(fields).filter(([, v]) => v !== undefined));
}

function seconds(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  const m = Math.round(s / 60);
  return m < 60 ? `${m}m` : `${Math.round(m / 60)}h`;
}

/** A machine as a human names it, falling back to the id it is addressed by. */
function machineName(m: { machineLabel?: string; machineId: string }): string {
  return m.machineLabel || m.machineId;
}

/** One directory row. The address leads, spelled by `memberAddress` so it reads
 *  the same here as on a thread — and it carries the project id because
 *  `sendTargetSchema` REQUIRES one and no other surface prints it: a row a
 *  caller cannot copy into `to` leaves them deriving the id by hand, and a
 *  wrong guess answers UNKNOWN_PEER, which reads as "that peer is gone" rather
 *  than "your address is malformed". The bracketed machine is the human's name
 *  for where, which is not what addresses it; the title makes the row
 *  judgeable, not addressable. */
function sessionLine(row: any, selfMachineId: string | null): string {
  const local = row.machineId === null || row.machineId === selfMachineId;
  const where = local ? "this machine" : machineName(row);
  const facts = [row.branch, row.activity, row.canReply ? "can reply" : "receive-only"].filter(Boolean);
  // An omitted machine means THIS machine on the way back in, so a local row is
  // spelled without one rather than echoing an id the caller never needs.
  const address = memberAddress({ ...row, machineId: local ? null : row.machineId });
  return `- [${where}] ${address} "${row.title}" — ${facts.join(", ")}`;
}

/** What one peer contributed, or why it contributed nothing. A machine that
 *  could not be asked is NAMED here rather than omitted: a peer missing from
 *  the list reads as a peer with nobody working on it. */
function reachMachineClause(m: any): string {
  const name = machineName(m);
  const dropped = m.droppedRows > 0 ? `, ${m.droppedRows} rows refused` : "";
  switch (m.status) {
    case "answered":
      return m.rows > 0
        ? `${name}: ${m.rows} session${m.rows === 1 ? "" : "s"}, read ${seconds(m.ageMs)} ago${dropped}`
        : `${name}: nothing on this repository as of ${seconds(m.ageMs)} ago${dropped}`;
    case "refused":
      return `${name}: remote access is off there`;
    case "reach-refused":
      return `${name}: reachable by agents is off there`;
    case "no-card":
      return `${name}: running a bridge older than this feature`;
    default:
      return m.rows > 0
        ? `${name}: did not answer; its ${m.rows} rows above were read ${seconds(m.ageMs)} ago`
        : `${name}: did not answer`;
  }
}

/** Printed in EVERY state, including a fully successful one. A signal that
 *  appears only on failure teaches an agent to read its absence as
 *  completeness, and "there is nobody else" is the one wrong answer a directory
 *  can give. */
function reachLine(reach: any): string {
  if (reach.scope === "machine") {
    switch (reach.why) {
      case "remote-access-off":
        return "Reach: remote access is off on this machine, so only its own sessions are listed.";
      case "no-machine-id":
        return "Reach: this machine has no relay identity yet, so nothing on it can be addressed from elsewhere and only its own sessions are listed.";
      default:
        return "Reach: no desktop app is carrying a cross-machine read for this machine, so only its own sessions are listed.";
    }
  }
  const parts = [`Reach: ${reach.machines.length} other machine${reach.machines.length === 1 ? "" : "s"} read ${seconds(reach.lastPushAgoMs)} ago.`];
  for (const m of reach.machines) parts.push(`${reachMachineClause(m)}.`);
  if (reach.notConnected > 0) {
    parts.push(`${reach.notConnected} machine${reach.notConnected === 1 ? "" : "s"} in your account ${reach.notConnected === 1 ? "is" : "are"} not connected to this desktop and ${reach.notConnected === 1 ? "was" : "were"} not asked.`);
  }
  return parts.join(" ");
}

function artifactLine(a: any): string {
  return `- ${a.artifactId} ${a.name} (${a.mediaType}, ${a.bytes} bytes): ${a.summary}`;
}

/** A member as it can be addressed back, which is the whole of what a
 *  correspondent is here: there is no name and no human behind it to greet. */
function memberAddress(ref: any): string {
  const machine = ref.machineId ? `${ref.machineId}/` : "";
  return `${machine}${ref.projectId}/${ref.sessionId}`;
}

/**
 * Who the caller is, written the way it has to travel.
 *
 * The machine is ALWAYS spelled, which is the one place this disagrees with
 * `sessionLine` — a directory row for a local session prints no machine, and is
 * right to, because it is read on the machine it means. This address is read
 * somewhere else by definition: that is what asking for it is for. Handed over
 * with the machine dropped it names the reader's own machine, and the send that
 * follows lands on a session that was never meant, or on none.
 *
 * Local mode has no machine to spell, so the answer says what that costs rather
 * than printing two thirds of an address and letting it be copied off this
 * machine.
 */
function selfLines(data: any): string[] {
  const where = data.projectLabel ? ` in project "${data.projectLabel}"` : "";
  const title = data.sessionName ? `"${data.sessionName}"${where}` : `unnamed${where}`;
  if (!data.machineId) {
    return [
      `You are ${title}, addressable as ${data.projectId}/${data.sessionId}.`,
      "This machine has no bus identity, so only a session on it can use that address.",
    ];
  }
  return [
    `You are ${title}, addressable as ${data.machineId}/${data.projectId}/${data.sessionId}.`,
    "Pass that address on exactly as written: one without a machine means the machine of whoever reads it.",
  ];
}

/** What a send owes its caller. The thread id because §4.3 makes it
 *  bridge-owned — an agent never told it cannot answer on the exchange it just
 *  opened — and whether the frame LEFT this machine, which is never a claim
 *  that it arrived: the receipt on antgrid_thread is the only witness to that. */
function sendLine(data: any): string {
  const opened = data.opensThread ? "Opened thread" : "On thread";
  const left = data.sent
    ? "It left this machine; whether it arrived shows as a receipt in antgrid_thread."
    : "It is held on this machine and has not left yet; it goes when the link is back.";
  return `${opened} ${data.threadId} (message ${data.messageId}). ${left} Use antgrid_reply with that thread id to answer.`;
}

/** One mailbox row: sender and thread lead, because together they are how it is
 *  answered, and the body follows indented under them so a reader needs no
 *  second call per post. */
function inboxLine(post: any): string {
  const thread = post.threadId ? `thread ${post.threadId}` : "no thread — it cannot be answered";
  const lines = [`- [${memberAddress(post.from)}] ${thread} — ${post.summary}`];
  for (const text of post.text ?? []) lines.push(`  ${text}`);
  if (post.unexpected) lines.push(`  Not asked about: ${post.unexpected}`);
  for (const artifact of post.artifacts ?? []) lines.push(`  ${artifactLine(artifact)}`);
  return lines.join("\n");
}

/** One thread entry, in the direction it travelled. An outbound entry always
 *  says whether it was acknowledged: an unacked message is never retried, so its
 *  silence is the whole of what the sender gets to know. */
function threadEntryLine(entry: any, now: number): string {
  const who = entry.direction === "out" ? "you" : memberAddress(entry.peer);
  const arrow = entry.direction === "out" ? "->" : "<-";
  const receipt = entry.direction !== "out"
    ? ""
    : entry.deliveredAt === undefined
      ? " [no receipt yet]"
      : ` [delivered ${seconds(now - entry.deliveredAt)} ago]`;
  const lines = [`- ${arrow} ${who}, ${seconds(now - entry.at)} ago${receipt} — ${entry.summary}`];
  for (const text of entry.text ?? []) lines.push(`  ${text}`);
  return lines.join("\n");
}

function argObj(args: Record<string, unknown> | undefined, key: string): Record<string, unknown> | undefined {
  const v = args?.[key];
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : undefined;
}

function argStrArr(args: Record<string, unknown> | undefined, key: string): string[] | undefined {
  const v = args?.[key];
  return Array.isArray(v) && v.every((e) => typeof e === "string") ? (v as string[]) : undefined;
}

/** Rebuilt key by key rather than forwarded whole, for the reason {@link body}
 *  exists: the target is `.strict()` too, so one key inside it that the route
 *  does not name refuses the entire send with a bare 400. A null machineId is
 *  kept — the route reads it as "this machine", the same as an absent one. */
function sendTarget(args: Record<string, unknown> | undefined): Record<string, unknown> | undefined {
  const to = argObj(args, "to");
  if (!to) return undefined;
  return body({
    machineId: to.machineId === null || typeof to.machineId === "string" ? to.machineId : undefined,
    projectId: typeof to.projectId === "string" ? to.projectId : undefined,
    sessionId: typeof to.sessionId === "string" ? to.sessionId : undefined,
  });
}

/** The fields the three send verbs share. One builder, because the routes share
 *  one body shape and a per-verb copy is how two of them drift into accepting
 *  different messages. */
function messageBody(args: Record<string, unknown> | undefined): Record<string, unknown> {
  return body({
    to: sendTarget(args),
    summary: argStr(args, "summary"),
    text: argStr(args, "text"),
    artifactIds: argStrArr(args, "artifactIds"),
    unexpected: argStr(args, "unexpected"),
    threadId: argStr(args, "threadId"),
  });
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
  switch (name) {
    case "antgrid_list_sessions": {
      const r = await api("GET", "/session-bus/sessions");
      if (!r.ok) return toolError(busError(r));
      const rows = (r.data.sessions ?? []) as any[];
      const self = (r.data.machineId ?? null) as string | null;
      const hidden = r.data.truncated > 0 ? `; ${r.data.truncated} more not shown` : "";
      const head = rows.length === 0
        ? "No other session is addressable from here."
        : `Sessions you can address (${rows.length}${hidden}):`;
      const body = rows.map((row) => sessionLine(row, self)).join("\n");
      return toolText([head, body, reachLine(r.data.reach)].filter(Boolean).join("\n"));
    }

    case "antgrid_whoami": {
      const r = await api("GET", "/session-bus/self");
      if (!r.ok) return toolError(busError(r));
      return toolText(selfLines(r.data).join("\n"));
    }

    case "antgrid_publish_artifact": {
      const r = await api("POST", "/session-bus/artifacts", body({
        name: argStr(args, "name"),
        summary: argStr(args, "summary"),
        content: argStr(args, "content"),
        contentBase64: argStr(args, "contentBase64"),
        mediaType: argStr(args, "mediaType"),
      }));
      if (!r.ok) return toolError(busError(r));
      const a = r.data.artifact;
      return toolText(`Published ${a.name} as ${a.artifactId} (${a.bytes} bytes). Name that id in a message to point the other side at it.`);
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

    case "antgrid_post":
    case "antgrid_notify":
    case "antgrid_reply": {
      const verb = name.slice("antgrid_".length);
      const r = await api("POST", `/session-bus/${verb}`, messageBody(args));
      if (!r.ok) return toolError(busError(r));
      return toolText(sendLine(r.data));
    }

    case "antgrid_inbox": {
      const r = await api("GET", "/session-bus/inbox");
      if (!r.ok) return toolError(busError(r));
      const posts = (r.data.posts ?? []) as any[];
      const dropped = (r.data.dropped ?? 0) as number;
      // The mailbox is bounded and drops its oldest, so a drop the reader is
      // never told about is a message that, as far as this session can tell, was
      // never sent. It rides the header the way the sessions head reports
      // truncation, and an emptied inbox says it as loudly as a full one.
      // Worded as the lifetime total it is: the store's counter is never reset,
      // so phrasing it as a delta would report the same losses on every read
      // and answer the one question worth asking — was anything lost since I
      // last looked — wrongly every time.
      const lost = dropped > 0
        ? `; ${dropped} post${dropped === 1 ? " has" : "s have"} been dropped unread from this mailbox since it was created`
        : "";
      const head = posts.length === 0
        ? `No unread posts${lost}.`
        : `Unread posts (${posts.length}${lost}). Reading them here marks them read:`;
      return toolText([head, ...posts.map(inboxLine)].join("\n"));
    }

    case "antgrid_thread": {
      const threadId = argStr(args, "threadId");
      if (!threadId) return toolError("Missing required argument: threadId");
      const r = await api("GET", `/session-bus/thread?threadId=${encodeURIComponent(threadId)}`);
      if (!r.ok) return toolError(busError(r));
      const entries = (r.data.entries ?? []) as any[];
      const now = Date.now();
      const head = `Thread ${r.data.threadId} (${entries.length} message${entries.length === 1 ? "" : "s"}, oldest first):`;
      return toolText([head, ...entries.map((entry) => threadEntryLine(entry, now))].join("\n"));
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
  ...SESSION_BUS_TOOLS,
];

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

  server.setRequestHandler(ListToolsRequestSchema, () => ({ tools: BASE_TOOLS }));

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
        // Dispatched by NAME, not by whether this process believes the call can
        // succeed: a bus tool must reach the bridge and be refused there, with the
        // reason the bridge authored — a local "unknown tool" would report a session
        // this bridge cannot answer for as a broken server.
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
