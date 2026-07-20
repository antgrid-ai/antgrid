import { join } from "node:path";
import { homedir } from "node:os";
import { writeFileSync, unlinkSync, readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { z } from "zod";
import { logger } from "./logger";
import { createMessage, type AbMessage } from "./protocol";
import type { TerminalManager } from "./terminal-manager";
import type { AbConfig } from "./config";
import type { ProjectInfo } from "./file-watcher";
import type { PairingWindow } from "./pairing-window";
import { lastAssistantText } from "./transcript-tail";

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
  /** Called when an injected hook pings /hook-alive (codex drift probe). */
  onHookAlive?: (terminalId: string) => void;
  /** Called when a turn-start hook pings /turn-start (a fresh turn began), so
   *  the control-plane work status resets to "working". Bridge-internal: this
   *  never emits an app-facing frame — unlike /notify, a turn-start is not a
   *  user-facing notification. */
  onTurnStart?: () => void;
  /**
   * Test-only accessor for the per-project pairing window. Wired in
   * `buildAgentCore` and only exposed via the `/test/open-pairing-window`
   * route when `ANTGRID_EVAL_TEST=1`.
   */
  pairingWindow?: () => PairingWindow;
}

const VERSION = "0.1.0";
const PORT_FILE = join(process.env.ANTGRID_DIR ?? join(homedir(), ".antgrid"), "api.port");

export const NotifyBodySchema = z.object({
  // Mirrors the notificationType enum in protocol.ts — validated here so the
  // bridge never emits a schema-invalid message onto the E2E channel.
  type: z.enum(["task_complete", "permission_request", "idle", "error"]),
  message: z.string().optional(),
  // Slot id (== ANTGRID_TERMINAL_ID) — names the session in the title.
  terminalId: z.string().optional(),
  // Hooks post pointers and the bridge reads.
  transcriptPath: z.string().optional(),
  agent: z.enum(["claude", "codex", "opencode", "gemini", "qwen", "github-copilot", "cursor"]).optional(),
});

export const SessionTitleSchema = z.object({
  terminalId: z.string().min(1),
  sessionId: z.string().min(1),
  title: z.string().optional(),
  transcriptPath: z.string().optional(),
  agent: z.enum(["claude", "codex", "opencode", "gemini", "qwen", "github-copilot", "cursor"]).optional(),
  titleOnly: z.boolean().optional(),
});
export type SessionTitleBody = z.infer<typeof SessionTitleSchema>;

const HandlerEventSchema = z.object({
  terminalId: z.string().min(1),
  agent: z.string().optional(),
  event: z.enum(["turn_end", "awaiting_input"]),
  transcriptPath: z.string().optional(),
  sessionId: z.string().optional(),
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

export function startApiServer(ctx: AgentContext): ApiServerHandle {
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

      // Test-only: open the pairing window and return the code. Used by the
      // eval harness to drive the pair flow E2E. Gated on ANTGRID_EVAL_TEST=1
      // so it is unreachable in production builds.
      if (
        req.method === "POST" &&
        path === "/test/open-pairing-window" &&
        process.env.ANTGRID_EVAL_TEST === "1" &&
        ctx.pairingWindow
      ) {
        try {
          const win = ctx.pairingWindow();
          const { code, expiresAt } = win.open();
          return json({ code, expiresAt });
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
        const project = ctx.project();
        const { type, terminalId, transcriptPath, agent } = parsed.data;
        // An agent that carries its final message inline wins; only claude needs
        // a read. Any miss leaves this undefined and compose.ts falls back to the
        // type label, so detail is strictly additive to today's behavior.
        let message = parsed.data.message;
        if (!message && agent === "claude" && transcriptPath) {
          message = (await lastAssistantText(transcriptPath)) ?? undefined;
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
          projectId: project.id,
        }));
        return json({ ok: true });
      }

      if (req.method === "POST" && path === "/turn-start") {
        // Body is accepted but not required — the api-server is per-core, so the
        // owning project is unambiguous without a terminalId. Drained so the
        // hook's POST doesn't block on an unread body.
        try { await req.json(); } catch { /* empty/invalid body is fine */ }
        ctx.onTurnStart?.();
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
    logger.warn("Failed to write API port file: %s", err);
  }

  logger.info("API server listening on http://127.0.0.1:%d", port);

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
