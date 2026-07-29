import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { z } from "zod";
import { MAX_NOTIFICATION_BODY_LEN } from "./transcript-tail";

export const MAX_HOOK_STDIN_BYTES = 64 * 1024;
// Fallback drain deadline for agents that emit hook JSON then hold stdin open
// (copilot does): the read normally resolves on stdin `end`, so this only bounds
// the hold-open case. Kept generous to match the deleted node scripts' ~4.5s
// budget — a 500ms cap truncated slow payloads and dropped the session id.
const HOOK_STDIN_TIMEOUT_MS = 4500;
// Upper bound on a single loopback POST. The deleted scripts were fire-and-forget
// (kernel-buffered, effectively unbounded); a 500ms abort dropped posts whenever
// the single-threaded bridge was busy > 500ms (e.g. /session-title reading a
// transcript). Loopback normally completes in milliseconds.
const HOOK_POST_TIMEOUT_MS = 4000;

// Per-agent event allowlist — the single source of truth for which events the
// runner acts on. Rust/serde agents serialize an absent field as JSON `null`,
// so every optional field is `.nullish()`; `.optional()` alone rejects `null`,
// which fails the whole parse and silently drops every post for that event.
// "user-prompt" (→ /turn-start) is Claude-specific: Claude exposes a
// UserPromptSubmit hook that fires before each new turn, and it is the ONLY
// turn-start signal a terminal-mode session has (chat sessions get precise
// `agent:turn-start` frames from their driver instead). Codex/Cursor/Copilot
// expose no pre-turn hook, so a terminal-mode session of those agents reads
// "done" while it works — the work-status reduction only calls a project
// working while a turn is open, and theirs never opens. Their turn-END hooks
// still deliver attention/error/done.
const HOOK_EVENTS: Record<string, readonly string[]> = {
  claude: ["session-start", "stop", "notification", "user-prompt"],
  codex: ["after-agent", "permission-request", "stop", "session-start"],
  cursor: ["session-start", "stop"],
  "github-copilot": ["session-start", "agent-stop"],
};

const ClaudePayloadSchema = z.object({
  session_id: z.string().nullish(),
  transcript_path: z.string().nullish(),
  message: z.string().nullish(),
});

const SessionPayloadSchema = z.object({
  session_id: z.string().nullish(),
  transcript_path: z.string().nullish(),
});

const CursorStopPayloadSchema = z.object({ status: z.string().nullish() });

const CodexPayloadSchema = z.object({
  "thread-id": z.string().nullish(),
  thread_id: z.string().nullish(),
});

// Codex's Stop hook stdin (StopCommandInput). last_assistant_message is a Rust
// NullableString — it arrives as null, not absent, so .nullish() is load-bearing:
// .optional() would reject null.
const CodexStopPayloadSchema = z.object({
  last_assistant_message: z.string().nullish(),
});

const CopilotPayloadSchema = z.object({
  sessionId: z.string().nullish(),
  session_id: z.string().nullish(),
  conversationId: z.string().nullish(),
  conversation_id: z.string().nullish(),
  session: z
    .object({
      id: z.string().nullish(),
      sessionId: z.string().nullish(),
    })
    .nullish(),
});

export type HookPath =
  | "/session-title"
  | "/notify"
  | "/handler-event"
  | "/turn-start"
  | "/hook-alive";

export interface HookPost {
  port: number;
  path: HookPath;
  body: Record<string, unknown>;
}

export interface HookInvocation {
  agent: string;
  event: string;
  payload?: string;
}

export interface HookRunnerDeps {
  env: Record<string, string | undefined>;
  readStdin: () => Promise<string>;
  readFile: (path: string) => string;
  post: (post: HookPost) => Promise<void>;
}

function parseJson(raw: string): unknown {
  try {
    return JSON.parse(raw.replace(/^\uFEFF/, ""));
  } catch {
    return {};
  }
}

function parsePort(raw: string | undefined): number | null {
  if (!raw || !/^\d+$/.test(raw.trim())) return null;
  const value = Number(raw.trim());
  return Number.isInteger(value) && value >= 1 && value <= 65535 ? value : null;
}

function resolvePort(
  agent: string,
  deps: Pick<HookRunnerDeps, "env" | "readFile">,
): number | null {
  const direct = parsePort(deps.env.ANTGRID_API_PORT);
  if (direct !== null) return direct;
  if (agent !== "github-copilot") return null;
  const dir = deps.env.ANTGRID_DIR || `${homedir()}/.antgrid`;
  try {
    return parsePort(deps.readFile(`${dir.replace(/[\\/]$/, "")}/api.port`));
  } catch {
    return null;
  }
}

function titlePost(
  port: number,
  terminalId: string | undefined,
  sessionId: string | null | undefined,
  agent: string,
  extra: Record<string, unknown> = {},
): HookPost | null {
  if (!terminalId || !sessionId) return null;
  return {
    port,
    path: "/session-title",
    body: { terminalId, sessionId, agent, ...extra },
  };
}

function parseOrEmpty<T>(schema: z.ZodType<T>, raw: string): T | null {
  const parsed = schema.safeParse(parseJson(raw));
  return parsed.success ? parsed.data : null;
}

async function buildPosts(
  invocation: HookInvocation,
  deps: HookRunnerDeps,
): Promise<HookPost[]> {
  if (!HOOK_EVENTS[invocation.agent]?.includes(invocation.event)) return [];
  const port = resolvePort(invocation.agent, deps);
  if (port === null) return [];
  const terminalId = deps.env.ANTGRID_TERMINAL_ID;
  const posts: Array<HookPost | null> = [];

  if (invocation.agent === "claude") {
    const input = parseOrEmpty(ClaudePayloadSchema, await deps.readStdin());
    if (!input) return [];
    if (invocation.event === "session-start" || invocation.event === "stop") {
      posts.push(
        titlePost(port, terminalId, input.session_id, "claude", {
          transcriptPath: input.transcript_path ?? "",
        }),
      );
    }
    if (invocation.event === "user-prompt") {
      // A fresh turn began — reset control-plane work status to "working" so a
      // re-prompt of an existing session (or one resumed after a granted
      // permission) stops showing the previous turn's done/attention. No
      // notification: this is state, not a user-facing alert.
      posts.push({
        port,
        path: "/turn-start",
        body: { ...(terminalId ? { terminalId } : {}) },
      });
    }
    if (invocation.event === "stop") {
      posts.push({
        port,
        path: "/notify",
        body: {
          type: "task_complete",
          agent: "claude",
          ...(terminalId ? { terminalId } : {}),
          ...(input.transcript_path ? { transcriptPath: input.transcript_path } : {}),
        },
      });
      if (terminalId) {
        posts.push({
          port,
          path: "/handler-event",
          body: {
            terminalId,
            agent: "claude",
            event: "turn_end",
            transcriptPath: input.transcript_path ?? "",
            sessionId: input.session_id ?? "",
          },
        });
      }
    }
    if (invocation.event === "notification") {
      if (terminalId) {
        posts.push({
          port,
          path: "/handler-event",
          body: {
            terminalId,
            agent: "claude",
            event: "awaiting_input",
            transcriptPath: input.transcript_path ?? "",
            sessionId: input.session_id ?? "",
          },
        });
      }
      // Claude Code fires this same "notification" hook, with the identical
      // "Claude is waiting for your input" message, both for a genuine mid-turn
      // block (e.g. a question tool with no stop event yet) and for its generic
      // post-completion idle nudge. We can't tell those apart from the message
      // alone, so tag it "awaiting_input" rather than "permission_request" and
      // let work-status.ts's turn-state-aware reduction decide whether it's a
      // live call-to-action or a stale nudge to ignore.
      const isWaitingNudge = !!input.message && /waiting/i.test(input.message);
      posts.push({
        port,
        path: "/notify",
        body: {
          type: isWaitingNudge ? "awaiting_input" : "permission_request",
          ...(terminalId ? { terminalId } : {}),
          ...(input.message ? { message: input.message } : {}),
        },
      });
    }
  } else if (invocation.agent === "codex") {
    if (invocation.event === "after-agent") {
      const input = parseOrEmpty(CodexPayloadSchema, invocation.payload ?? "");
      if (!input || !terminalId) return [];
      const sessionId = input["thread-id"] ?? input.thread_id;
      posts.push(titlePost(port, terminalId, sessionId, "codex"));
      posts.push({
        port,
        path: "/handler-event",
        body: { terminalId, agent: "codex", event: "turn_end" },
      });
    } else {
      const raw = await deps.readStdin();
      if (invocation.event === "permission-request") {
        posts.push({ port, path: "/notify", body: { type: "permission_request", ...(terminalId ? { terminalId } : {}) } });
      } else if (invocation.event === "stop") {
        // Parse failures fall through to a bare notify rather than returning:
        // a turn-end notification must survive a payload we can't read.
        const message = parseOrEmpty(CodexStopPayloadSchema, raw)?.last_assistant_message?.trim();
        posts.push({
          port,
          path: "/notify",
          body: {
            type: "task_complete",
            ...(terminalId ? { terminalId } : {}),
            ...(message ? { message: message.slice(0, MAX_NOTIFICATION_BODY_LEN) } : {}),
          },
        });
      } else if (terminalId) {
        posts.push({ port, path: "/hook-alive", body: { terminalId } });
      }
    }
  } else if (invocation.agent === "cursor") {
    const raw = await deps.readStdin();
    if (invocation.event === "session-start") {
      const input = parseOrEmpty(SessionPayloadSchema, raw);
      if (!input) return [];
      posts.push(titlePost(port, terminalId, input.session_id, "cursor"));
    } else {
      const input = parseOrEmpty(CursorStopPayloadSchema, raw);
      if (input?.status === "completed" && terminalId) {
        posts.push({ port, path: "/notify", body: { type: "task_complete", terminalId } });
      }
    }
  } else if (invocation.agent === "github-copilot") {
    const input = parseOrEmpty(CopilotPayloadSchema, await deps.readStdin());
    if (!input) return [];
    const sessionId =
      input.sessionId ??
      input.session_id ??
      input.session?.id ??
      input.session?.sessionId ??
      input.conversationId ??
      input.conversation_id;
    posts.push(
      titlePost(port, terminalId, sessionId, "github-copilot", {
        ...(invocation.event === "agent-stop" ? { titleOnly: true } : {}),
      }),
    );
  }

  return posts.filter((post): post is HookPost => post !== null);
}

async function defaultPost(post: HookPost): Promise<void> {
  await fetch(`http://127.0.0.1:${post.port}${post.path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(post.body),
    signal: AbortSignal.timeout(HOOK_POST_TIMEOUT_MS),
  });
}

function defaultDeps(): HookRunnerDeps {
  return {
    env: process.env,
    readStdin: () => readHookStdin(process.stdin),
    readFile: (path) => readFileSync(path, "utf8"),
    post: defaultPost,
  };
}

export async function runHookInvocation(
  invocation: HookInvocation,
  deps: HookRunnerDeps = defaultDeps(),
): Promise<void> {
  try {
    const posts = await buildPosts(invocation, deps);
    await Promise.allSettled(posts.map((post) => deps.post(post)));
  } catch {
    // Hooks are advisory; an integration failure must never block the agent.
  }
}

export function readHookStdin(
  stdin: NodeJS.ReadableStream,
  timeoutMs: number = HOOK_STDIN_TIMEOUT_MS,
): Promise<string> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;
    const onData = (chunk: string | Buffer) => {
      if (bytes >= MAX_HOOK_STDIN_BYTES) return;
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
      const remaining = MAX_HOOK_STDIN_BYTES - bytes;
      const accepted = buffer.subarray(0, remaining);
      chunks.push(accepted);
      bytes += accepted.length;
    };
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      // Detach every listener and unref the handle so a stdin the agent left
      // open can't keep this short-lived hook process alive past resolution.
      stdin.removeListener("data", onData);
      stdin.removeListener("end", finish);
      stdin.removeListener("error", finish);
      (stdin as NodeJS.ReadableStream & { unref?: () => void }).unref?.();
      resolve(Buffer.concat(chunks, bytes).toString("utf8"));
    };
    stdin.on("data", onData);
    stdin.once("end", finish);
    stdin.once("error", finish);
    const timer = setTimeout(finish, timeoutMs);
  });
}
