import { join } from "node:path";
import { writeFileSync, unlinkSync, readFileSync, mkdirSync } from "node:fs";
import { spawn } from "node:child_process";
import { z } from "zod";
import { logger } from "./logger";
import { resolveAbDir } from "./antgrid-dir";
const log = logger.child({ component: "api-server" });
import { createMessage, type AbMessage } from "./protocol";
import { AGENTS, BY_HOOK_NAME } from "./agents/registry";
import type { TerminalManager } from "./terminal-manager";
import type { AbConfig } from "./config";
import type { ProjectInfo } from "./file-watcher";
import {
  PublishArtifactBodySchema,
  type SessionBusApi,
} from "./session-bus/api";
import { ARTIFACT_CHUNK_BYTES } from "./session-bus/constants";
import { SESSION_BUS_ERRORS, isRefusal } from "./session-bus/errors";

/** The tree one caller of this API works in: its own `antgrid.yaml`, and the
 *  filesystem root a command it names must run against. */
export interface CallerCheckout {
  id: string;
  path: string;
  config: AbConfig;
}

export interface AgentContext {
  manager: () => TerminalManager | null;
  config: () => AbConfig;
  project: () => ProjectInfo;
  sendAb: (msg: AbMessage) => void;
  /** Which checkout a caller's terminal actually runs in. This API is per CORE,
   *  so an isolated session's agent reaches it on the same port main's does and
   *  the slot it was spawned with (`ANTGRID_TERMINAL_ID`, forwarded into the MCP
   *  server's environment) is the only thing that says which tree is its own —
   *  checkout-scoped routing one level below the message plane. Wired in
   *  buildAgentCore; absent, or an id no terminal claims, is the project's own
   *  checkout, which is also what a terminal-less caller gets. */
  checkoutFor?: (terminalId?: string) => CallerCheckout;
  /** Current session name for a slot id, for the notification title. Wired in
   *  buildAgentCore to SessionManager.get(); undefined for service PTYs. */
  sessionName?: (terminalId: string) => string | undefined;
  /** Forwarded a validated /session-title POST from an injected agent hook/
   *  plugin. Wired in buildAgentCore to resolve + feed the SessionNamer. */
  onSessionTitle?: (body: SessionTitleBody) => void;
  /** Forwarded a validated /handler-event POST from an injected agent hook. */
  onHandlerEvent?: (body: HandlerEventBody) => void;
  /** True when a hook's `awaiting_input` for this slot can only be the generic
   *  post-completion idle nudge, because the slot's own turn already ended.
   *  Wired in buildAgentCore to the owner's work-status reduction — the same
   *  fold that already skips the nudge's phone push, so the two rules cannot
   *  drift apart.
   *
   *  ABSENT MEANS FORWARD, and that is the safe direction: a genuine mid-turn
   *  block that never reaches the Handler leaves a blocked agent unsupervised,
   *  with no further event able to raise it. */
  isStaleIdleNudge?: (terminalId: string) => boolean;
  /** Called when an injected hook pings /hook-alive, the drift probe for any
   *  agent whose `hooks.posts` declares that path. */
  onHookAlive?: (terminalId: string) => void;
  /** Called when a turn-start hook pings /turn-start (a fresh turn began), so
   *  the control-plane work status resets to "working". `terminalId` is the slot
   *  the hook was stamped with, when it posted one — absent when the hook had no
   *  ANTGRID_TERMINAL_ID in its env, which still resets the project-level
   *  status. Bridge-internal: this never emits an app-facing frame — unlike
   *  /notify, a turn-start is not a user-facing notification. */
  onTurnStart?: (terminalId?: string) => void;
  /** The session bus, when this core built one. Every decision the
   *  `/session-bus/*` routes make is made in here, so the MCP tools above them
   *  stay a transport and cannot answer differently from the routes. Absent
   *  means the core has no bus at all (a test core, or one built before the
   *  session manager was ready), and every route answers 503 rather than
   *  refusing the caller — which would leave an agent unable to publish with
   *  nothing saying why. */
  sessionBus?: SessionBusApi;
}

const VERSION = "0.1.0";

/**
 * The hook-name vocabulary a loopback post may identify itself by (`claude`,
 * `cursor`, … — NOT registry keys), derived from the registry rather than
 * listed.
 *
 * Hand-listing it is a silent break: an agent whose `hookName` is missing here
 * has its posts rejected 400, and `runHookInvocation` swallows the failure — so
 * the new agent launches, runs, and simply never names its sessions, with no
 * compile error and no log line to find.
 */
const HOOK_AGENT_NAMES = Object.keys(BY_HOOK_NAME) as [string, ...string[]];

export const NotifyBodySchema = z.object({
  // Mirrors the notificationType enum in protocol.ts — validated here so the
  // bridge never emits a schema-invalid message onto the E2E channel.
  type: z.enum(["task_complete", "permission_request", "idle", "error"]),
  message: z.string().optional(),
  // Slot id (== ANTGRID_TERMINAL_ID) — names the session in the title.
  terminalId: z.string().optional(),
  // Hooks post pointers and the bridge reads.
  transcriptPath: z.string().optional(),
  agent: z.enum(HOOK_AGENT_NAMES).optional(),
});

export const SessionTitleSchema = z.object({
  terminalId: z.string().min(1),
  sessionId: z.string().min(1),
  /** The message the user just submitted, from an agent with a PRE-turn hook
   *  (only Claude has one). Its presence is what makes this post a request to
   *  name the session now rather than a report that a turn ended, so it must
   *  never be set on a turn-end post. */
  prompt: z.string().optional(),
  transcriptPath: z.string().optional(),
  agent: z.enum(HOOK_AGENT_NAMES).optional(),
  titleOnly: z.boolean().optional(),
});
export type SessionTitleBody = z.infer<typeof SessionTitleSchema>;

const HandlerEventSchema = z.object({
  terminalId: z.string().min(1),
  agent: z.string().optional(),
  event: z.enum(["turn_end", "awaiting_input", "limit_hit", "limit_cleared", "turn_failed"]),
  transcriptPath: z.string().optional(),
  sessionId: z.string().optional(),
  // Lifecycle detail: when the provider's limit window ends (epoch ms; absent →
  // the engine's fallback wait) and what the driver called the failure.
  resetsAt: z.number().optional(),
  errorClass: z.string().optional(),
  // `awaiting_input` only: the poster's own reading of the message it saw — true
  // when it looks like the agent's generic idle nudge, false when the same hook
  // classified it as a live block. Nothing else can tell them apart, and the
  // paired /notify from the SAME invocation is decided on it, so the drop below
  // has to read it or the two answers disagree. Absent = the poster did not say.
  idleNudge: z.boolean().optional(),
});
export type HandlerEventBody = z.infer<typeof HandlerEventSchema>;

export interface ApiServerHandle {
  readonly port: number;
  stop(): void;
}

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function textResponse(data: string, status = 200) {
  return new Response(data, { status, headers: { "Content-Type": "text/plain" } });
}

/** One rendering for every session-bus answer: a refusal becomes its own status
 *  and code, a result becomes 200. The status comes from `SESSION_BUS_ERRORS`, so
 *  a route and the tool calling it can never disagree about what a code means. */
function sessionBusJson(result: unknown): Response {
  if (isRefusal(result)) {
    return json({ error: result.error, code: result.code }, SESSION_BUS_ERRORS[result.code]);
  }
  return json(result);
}

function sessionBusPost<T>(schema: z.ZodType<T>, body: unknown, run: (b: T) => unknown): Response {
  const parsed = schema.safeParse(body);
  if (!parsed.success) return json({ error: "Invalid body" }, 400);
  return sessionBusJson(run(parsed.data));
}

/** A non-negative integer query param, or [fallback] for anything else. A caller
 *  that spelled a range badly reads from the start rather than being refused:
 *  the artifact read is clamped to one chunk on the bridge side anyway. */
function intParam(url: URL, name: string, fallback: number): number {
  const raw = url.searchParams.get(name);
  if (raw === null) return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

// Cursor merges hook tiers, so a machine with both the project-tier entries
// (plugin installer) and the user-tier entries (spawn augmenter) runs two
// identical hook processes per event, and both POST /notify. Collapse exact
// duplicates inside a short window so the phone gets one notification.
const NOTIFY_DEDUP_WINDOW_MS = 5_000;

export function startApiServer(ctx: AgentContext): ApiServerHandle {
  const recentNotifies = new Map<string, number>();

  /** The checkout the caller of this request works in. A caller names itself
   *  with `?terminalId=`; anything else is answered out of the project's own
   *  checkout, which is what every pre-checkout caller already got. */
  function callerCheckout(url: URL): CallerCheckout {
    const terminalId = url.searchParams.get("terminalId") ?? undefined;
    return ctx.checkoutFor?.(terminalId)
      ?? { id: "main", path: ctx.project().path, config: ctx.config() };
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(req) {
      const url = new URL(req.url);
      const path = url.pathname;

      if (req.method === "GET" && path === "/health") {
        return json({ ok: true, version: VERSION });
      }

      if (req.method === "GET" && path === "/config") {
        const config = callerCheckout(url).config;
        return json({
          commands: config.commands ?? [],
          services: config.services ?? [],
          ports: config.ports ?? [],
        });
      }

      if (req.method === "GET" && path === "/terminals") {
        const mgr = ctx.manager();
        if (!mgr) return json({ error: "Agent not ready" }, 503);

        const all = url.searchParams.get("all") === "true";
        const caller = callerCheckout(url);
        let terminals = mgr.getStatus();
        if (!all) {
          terminals = terminals.filter((t) => t.type !== "agent");
        }
        // A core runs the terminals of every checkout under it, so a caller
        // inside an isolated session must see its own and no one else's — the
        // scrollback of another session's agent is not context, it is someone
        // else's conversation.
        if (ctx.checkoutFor) {
          terminals = terminals.filter((t) => ctx.checkoutFor!(t.terminalId).id === caller.id);
        }
        return json(terminals);
      }

      if (req.method === "GET" && path.startsWith("/terminals/") && path.endsWith("/scrollback")) {
        const scrollbackMatch = path.match(/^\/terminals\/([^/]+)\/scrollback$/);
        if (!scrollbackMatch) return json({ error: "Not found" }, 404);
        const mgr = ctx.manager();
        if (!mgr) return json({ error: "Agent not ready" }, 503);

        const terminalId = decodeURIComponent(scrollbackMatch[1]);
        // Same answer as a terminal that does not exist, deliberately: a caller
        // in another checkout must not learn this one is there.
        if (ctx.checkoutFor && ctx.checkoutFor(terminalId).id !== callerCheckout(url).id) {
          return json({ error: "Terminal not found" }, 404);
        }
        const snap = mgr.getScrollback(terminalId);
        if (snap === null) {
          return json({ error: "Terminal not found" }, 404);
        }
        return textResponse(snap.text);
      }

      if (req.method === "POST" && path.startsWith("/commands/") && path.endsWith("/run")) {
        const cmdMatch = path.match(/^\/commands\/([^/]+)\/run$/);
        if (!cmdMatch) return json({ error: "Not found" }, 404);
        const commandName = decodeURIComponent(cmdMatch[1]);
        // Both the definition and the tree it runs in come from the CALLER's
        // checkout: an isolated session's agent running `build` against main's
        // working tree builds another session's uncommitted work and reads the
        // result as its own.
        const caller = callerCheckout(url);
        const project = ctx.project();

        const cmdConfig = caller.config.commands?.find((c) => c.name === commandName);
        if (!cmdConfig) {
          return json({ error: `Unknown command: ${commandName}` }, 404);
        }

        // Enforce confirm gate — same security boundary as the WebSocket handler
        if (cmdConfig.confirm) {
          let confirmed = false;
          try {
            const body = await req.json() as { confirmed?: boolean };
            confirmed = body.confirmed === true;
          } catch { /* no body or invalid JSON → not confirmed */ }
          if (!confirmed) {
            return json({ error: `Command '${commandName}' requires confirmation. Pass { "confirmed": true } in request body.` }, 403);
          }
        }

        const args = cmdConfig.args ?? [];
        const cwd = cmdConfig.workingDir ?? caller.path;
        const env = cmdConfig.env ? { ...process.env, ...cmdConfig.env } : undefined;

        try {
          const proc = spawn(cmdConfig.command, args, {
            cwd,
            env,
            shell: true,
            stdio: ["ignore", "pipe", "pipe"],
          });

          const MAX_OUTPUT = 1024 * 1024;
          const chunks: string[] = [];
          let outputLen = 0;

          const collectStream = (stream: NodeJS.ReadableStream) => {
            stream.on("data", (chunk: Buffer) => {
              const text = chunk.toString();
              if (outputLen < MAX_OUTPUT) {
                chunks.push(text);
                outputLen += text.length;
              }
              ctx.sendAb(createMessage("command:output", {
                projectId: project.id,
                checkoutId: caller.id,
                commandName,
                data: text,
              }));
            });
          };

          if (proc.stdout) collectStream(proc.stdout);
          if (proc.stderr) collectStream(proc.stderr);

          const exitCode = await new Promise<number | null>((resolve) => {
            proc.on("close", resolve);
            proc.on("error", (err) => {
              chunks.push(`Error: ${err.message}\n`);
              resolve(1);
            });
          });

          ctx.sendAb(createMessage("command:done", {
            projectId: project.id,
            checkoutId: caller.id,
            commandName,
            exitCode,
          }));

          return json({ exitCode, output: chunks.join("") });
        } catch (err) {
          return json({ error: String(err) }, 500);
        }
      }

      if (req.method === "POST" && path === "/notify") {
        let raw: unknown;
        try {
          raw = await req.json();
        } catch {
          return json({ error: "Invalid JSON body" }, 400);
        }
        const parsed = NotifyBodySchema.safeParse(raw);
        if (!parsed.success) return json({ error: "Invalid body" }, 400);
        const dedupKey = JSON.stringify(parsed.data);
        const now = Date.now();
        for (const [key, at] of recentNotifies) {
          if (now - at > NOTIFY_DEDUP_WINDOW_MS) recentNotifies.delete(key);
        }
        if (recentNotifies.has(dedupKey)) return json({ ok: true, deduped: true });
        recentNotifies.set(dedupKey, now);
        const project = ctx.project();
        const { type, terminalId, transcriptPath, agent } = parsed.data;
        // An agent that carries its final message inline wins; only an agent
        // whose spec declares a transcript reader pays for a read. Any miss
        // leaves this undefined and compose.ts falls back to the type label, so
        // detail is strictly additive to today's behavior. `agent` is a hook
        // name, hence the BY_HOOK_NAME hop.
        let message = parsed.data.message;
        if (!message && transcriptPath) {
          const key = agent ? BY_HOOK_NAME[agent] : undefined;
          const read = key ? AGENTS[key].notifyBodyFromTranscript : undefined;
          if (read) message = (await read(transcriptPath)) ?? undefined;
        }
        // Read, don't resolve: the namer pipeline already owns this title, and it
        // comes from the transcript's HEAD while the body comes from its TAIL.
        // Stale on turn 1 only — /session-title races this post and resolves
        // async, but the title is conversation-level and stable from turn 2 on.
        const sessionTitle = terminalId ? ctx.sessionName?.(terminalId) : undefined;
        ctx.sendAb(createMessage("notification:push", {
          notificationType: type,
          message,
          sessionTitle,
          // Unresolved on purpose: this is whatever slot the hook was stamped
          // with, and only the SessionManager knows which ids are sessions.
          sessionId: terminalId,
          projectId: project.id,
        }));
        return json({ ok: true });
      }

      if (req.method === "POST" && path === "/turn-start") {
        // terminalId is accepted but not required — the api-server is per-core,
        // so the owning project is unambiguous without one. The id, when the
        // hook had one, scopes the open turn to that session so a sibling's
        // turn-end can't close it. Drained either way so the hook's POST doesn't
        // block on an unread body.
        let terminalId: string | undefined;
        try {
          const body = await req.json() as { terminalId?: unknown } | null;
          if (typeof body?.terminalId === "string") terminalId = body.terminalId;
        } catch { /* empty/invalid body is fine */ }
        ctx.onTurnStart?.(terminalId);
        return json({ ok: true });
      }

      if (req.method === "POST" && path === "/hook-alive") {
        try {
          const body = await req.json() as { terminalId?: string };
          if (body.terminalId) ctx.onHookAlive?.(body.terminalId);
          return json({ ok: true });
        } catch {
          return json({ error: "Invalid JSON body" }, 400);
        }
      }

      if (req.method === "POST" && path === "/session-title") {
        let body: unknown;
        try {
          body = await req.json();
        } catch {
          return json({ error: "Invalid JSON body" }, 400);
        }
        const parsed = SessionTitleSchema.safeParse(body);
        if (!parsed.success) return json({ error: "Invalid body" }, 400);
        ctx.onSessionTitle?.(parsed.data);
        return json({ ok: true });
      }

      if (req.method === "POST" && path === "/handler-event") {
        let body: unknown;
        try { body = await req.json(); } catch { return json({ error: "Invalid JSON body" }, 400); }
        const parsed = HandlerEventSchema.safeParse(body);
        if (!parsed.success) return json({ error: "Invalid body" }, 400);
        // The agent's notification hook is stateless: it fires the identical
        // "waiting for your input" signal for a real mid-turn block and for its
        // idle nudge after the turn already ended. Only the host knows which,
        // and forwarding the second costs the Handler a context assemble plus a
        // judge spawn on a turn nothing can change any more. Asked for this ONE
        // event kind — the turn/limit kinds are unambiguous and must never be
        // gated on turn state. Still 200: the hook must not see a failure.
        //
        // BOTH halves are required. The reduction is read before the paired
        // /notify of the same hook invocation has folded into it (that POST is
        // issued alongside this one and lands after), so turn state alone would
        // classify a genuine mid-turn block as an idle nudge whenever the slot's
        // last notification was a turn-end — reachable from a lost /turn-start, or
        // from Handler's own park push, which writes task_complete for the slot.
        // The Handler would then never hear the block while the same invocation's
        // /notify dotted the session "needs you", and nothing re-raises it.
        // `idleNudge` is the poster's own reading of the message, which is exactly
        // what /notify branches on: unless it says this is the nudge shape, forward.
        if (parsed.data.event === "awaiting_input" && parsed.data.idleNudge === true
          && ctx.isStaleIdleNudge?.(parsed.data.terminalId)) {
          log.debug("Dropped a post-completion idle nudge for %s", parsed.data.terminalId);
          return json({ ok: true, stale: true });
        }
        ctx.onHandlerEvent?.(parsed.data);
        return json({ ok: true });
      }

      // The session bus. Every route resolves the CALLER from `?terminalId=` —
      // the slot `ANTGRID_TERMINAL_ID` stamped into the agent's environment,
      // which the MCP server puts on every request. The terminal id IS the
      // session id for an agent session, which is what says whose artifacts are
      // being asked for; a service PTY names none and resolves to no session.
      if (path.startsWith("/session-bus/")) {
        const bus = ctx.sessionBus;
        if (!bus) return json({ error: "Session bus not available", code: "AGENT_NOT_READY" }, 503);
        const terminalId = url.searchParams.get("terminalId") ?? undefined;
        const rest = path.slice("/session-bus/".length);

        if (req.method === "GET") {
          if (rest === "artifacts") return sessionBusJson(bus.listArtifacts(terminalId));
          if (rest === "sessions") return sessionBusJson(await bus.listSessions(terminalId));
          const artifact = rest.match(/^artifacts\/([^/]+)$/);
          if (artifact) {
            return sessionBusJson(bus.getArtifact(
              terminalId,
              decodeURIComponent(artifact[1]),
              intParam(url, "offset", 0),
              intParam(url, "length", ARTIFACT_CHUNK_BYTES),
            ));
          }
          return json({ error: "Not found" }, 404);
        }

        if (req.method !== "POST") return json({ error: "Not found" }, 404);

        // An unreadable body is treated as an absent one rather than answered
        // 400 here: the POST below validates with its own schema, so the refusal
        // is identical.
        let body: unknown;
        try { body = await req.json(); } catch { body = undefined; }

        if (rest === "artifacts") {
          return sessionBusPost(PublishArtifactBodySchema, body, (b) => bus.publishArtifact(terminalId, b));
        }
        return json({ error: "Not found" }, 404);
      }

      return json({ error: "Not found" }, 404);
    },
  });

  const port = server.port!;

  // Best-effort port file for MCP server / hook discovery. This is a single
  // shared path, so with the singleton host running N cores it only ever holds
  // the most-recently-started core's port (last writer wins). The per-core
  // ANTGRID_API_PORT env var stamped into each terminal is the real source of
  // truth; this file is a fallback for processes that lack that env (legacy /
  // single-core). See stop() for why removal is guarded.
  // Resolved per server, never at module load: ANTGRID_DIR is the process-wide
  // override every other reader honours live (`resolveAbDir`, and hook-runner's
  // own fallback), so a path frozen at import time answers for whatever the env
  // held when the first module in the graph loaded. The directory may not exist
  // yet on a first launch, and losing the file costs hook discovery silently.
  const portFile = join(resolveAbDir(), "api.port");
  try {
    mkdirSync(join(portFile, ".."), { recursive: true });
    writeFileSync(portFile, String(port), { mode: 0o600 });
  } catch (err) {
    log.warn("Failed to write API port file: %s", err);
  }

  log.info("API server listening on http://127.0.0.1:%d", port);

  let stopped = false;
  return {
    port,
    stop() {
      if (stopped) return;
      stopped = true;
      server.stop();
      // Only remove the shared port file if it still points at THIS core. Under
      // the singleton host a later core may have overwritten it; an
      // unconditional unlink would delete a sibling core's live pointer.
      try {
        if (readFileSync(portFile, "utf8").trim() === String(port)) unlinkSync(portFile);
      } catch {
        // Port file may not exist or be unreadable — nothing to clean up.
      }
    },
  };
}
