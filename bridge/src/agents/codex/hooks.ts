import { z } from "zod";
import {
  computeCommandHookHash,
  hookStateKey,
  EVENT_LABELS,
} from "../../codex-hook-fingerprint";
import {
  hookArgv,
  hookShellCommand,
  resolveHookCommand,
  type HookCommand,
} from "../../hook-command";
import { MAX_NOTIFICATION_BODY_LEN } from "../../transcript-tail";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const CODEX_HOOK_TIMEOUT = 600;

function tomlBasicString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function toPosixPath(value: string): string {
  return value.replace(/\\/g, "/");
}

export function buildCodexNotifyInjection(
  command: HookCommand = resolveHookCommand(),
): string[] {
  const commandFor = (event: string) =>
    hookShellCommand(command, "codex", event);
  const def = (event: string, commandEvent: string) =>
    `hooks.${event}=[{hooks=[{type="command",command="${tomlBasicString(commandFor(commandEvent))}"}]}]`;

  const events: Array<{ event: string; label: string; commandEvent: string }> = [
    { event: "PermissionRequest", label: EVENT_LABELS.PermissionRequest, commandEvent: "permission-request" },
    { event: "Stop", label: EVENT_LABELS.Stop, commandEvent: "stop" },
    { event: "SessionStart", label: EVENT_LABELS.SessionStart, commandEvent: "session-start" },
  ];
  const stateEntries = events
    .map(({ label, commandEvent }) => {
      const hash = computeCommandHookHash({
        eventLabel: label,
        command: commandFor(commandEvent),
        timeoutSec: CODEX_HOOK_TIMEOUT,
      });
      return `'${hookStateKey(label, 0, 0)}'={trusted_hash="${hash}"}`;
    })
    .join(",");

  const args: string[] = [];
  for (const { event, commandEvent } of events) {
    args.push("-c", def(event, commandEvent));
  }
  args.push("-c", `hooks.state={${stateEntries}}`);
  return args;
}

export function inject({ hookCommand }: HookInjectCtx): LaunchAugmentation {
  const notifyArgv = hookArgv(hookCommand, "codex", "after-agent").map(toPosixPath);
  return {
    args: [
      "-c",
      `notify=${JSON.stringify(notifyArgv)}`,
      ...buildCodexNotifyInjection(hookCommand),
    ],
    env: {},
  };
}

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

export const events = ["after-agent", "permission-request", "stop", "session-start"] as const;

export async function toPosts(
  invocation: HookInvocation,
  { port, terminalId, readStdin }: HookPostCtx,
): Promise<HookPost[]> {
  const posts: Array<HookPost | null> = [];
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
    // Drained before the event branch, not inside it: codex writes hook stdin
    // for every one of these events and a pipe nobody reads can block it.
    const raw = await readStdin();
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

  return compact(posts);
}
