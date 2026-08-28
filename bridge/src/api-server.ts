import { join } from "node:path";
import { homedir } from "node:os";
import { writeFileSync, unlinkSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { z } from "zod";
import { logger } from "./logger";
const log = logger.child({ component: "api-server" });
import { createMessage, type AbMessage } from "./protocol";
import { AGENTS, BY_HOOK_NAME } from "./agents/registry";
import type { TerminalManager } from "./terminal-manager";
import type { AbConfig } from "./config";
import type { ProjectInfo } from "./file-watcher";

export interface AgentContext {
  manager: () => TerminalManager | null;
  config: () => AbConfig;
  project: () => ProjectInfo;
  sendAb: (msg: AbMessage) => void;
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
}

const VERSION = "0.1.0";
const PORT_FILE = join(process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid"), "api.port");

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

// Cursor merges hook tiers, so a machine with both the project-tier entries
// (plugin installer) and the user-tier entries (spawn augmenter) runs two
// identical hook processes per event, and both POST /notify. Collapse exact
// duplicates inside a short window so the phone gets one notification.
const NOTIFY_DEDUP_WINDOW_MS = 5_000;

export function startApiServer(ctx: AgentContext): ApiServerHandle {
  const recentNotifies = new Map<string, number>();
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
        const config = ctx.config();
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
        let terminals = mgr.getStatus();
        if (!all) {
          terminals = terminals.filter((t) => t.type !== "agent");
        }
        return json(terminals);
      }

      if (req.method === "GET" && path.startsWith("/terminals/") && path.endsWith("/scrollback")) {
        const scrollbackMatch = path.match(/^\/terminals\/([^/]+)\/scrollback$/);
        if (!scrollbackMatch) return json({ error: "Not found" }, 404);
        const mgr = ctx.manager();
        if (!mgr) return json({ error: "Agent not ready" }, 503);

        const terminalId = decodeURIComponent(scrollbackMatch[1]);
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
        const config = ctx.config();
        const project = ctx.project();

        const cmdConfig = config.commands?.find((c) => c.name === commandName);
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
        const cwd = cmdConfig.workingDir ?? project.path;
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
  try {
    writeFileSync(PORT_FILE, String(port), { mode: 0o600 });
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
        if (readFileSync(PORT_FILE, "utf8").trim() === String(port)) unlinkSync(PORT_FILE);
      } catch {
        // Port file may not exist or be unreadable — nothing to clean up.
      }
    },
  };
}
