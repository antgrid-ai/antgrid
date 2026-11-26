import { resolveHookCommand } from "../../host";
import { z } from "zod";
import {
  computeCommandHookHash,
  hookStateKey,
  EVENT_LABELS,
} from "./hook-fingerprint";
import {
  hookArgv,
  hookShellCommand,
  type HookCommand,
} from "../../hook-command";
import { MAX_NOTIFICATION_BODY_LEN } from "../../transcript-tail";
import { compact, namesTheSession, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import { toPosixPath } from "../launch-inject";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const CODEX_HOOK_TIMEOUT = 600;

function tomlBasicString(value: string): string {
  return value.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

export function buildCodexNotifyInjection(
  command: HookCommand = resolveHookCommand(),
): string[] {
  const commandFor = (event: string) =>
    hookShellCommand(command, "codex", event);
  const def = (event: string, commandEvent: string) =>
    `hooks.${event}=[{hooks=[{type="command",command="${tomlBasicString(commandFor(commandEvent))}"}]}]`;

  const events: Array<{ event: string; label: string; commandEvent: string }> = [
    { event: "Stop", label: EVENT_LABELS.Stop, commandEvent: "stop" },
    { event: "SessionStart", label: EVENT_LABELS.SessionStart, commandEvent: "session-start" },
    // UserPromptSubmit (below) fires once, at the start of a turn — a long
    // multi-tool turn still needs something to re-assert "working" between
    // sibling tool calls, which is this event's whole job. The Claude side's
    // catch-all PostToolUse has the same job.
    // Registered synchronous (no `async=true`, unlike the Claude side): codex's
    // hook_config.rs support for that field on a command handler is unconfirmed
    // against the pinned version, and a wrong guess there breaks trusted_hash
    // silently (see the fingerprint comment above) rather than merely costing
    // CPU. The cost is one hook spawn on every Codex tool call: about 0.6 s on
    // Windows with the packaged bridge (PowerShell is 0.16 s of it).
    { event: "PostToolUse", label: EVENT_LABELS.PostToolUse, commandEvent: "post-tool-use" },
    // A real turn-start: measured (bun-pty probe) to fire exactly once per
    // submitted prompt, before the model turn, and not for /status, /new or
    // /compact. Lets `needsKeystrokeTurnStart` drop codex — see registry.ts.
    { event: "UserPromptSubmit", label: EVENT_LABELS.UserPromptSubmit, commandEvent: "user-prompt" },
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
      // PermissionRequest precedes automatic review and cannot tell us whether
      // the user is needed. Let the TUI emit actual approval prompts instead.
      // Stop owns completion notifications, so exclude agent-turn-complete.
      "-c", 'tui.notifications=["approval-requested"]',
      "-c", 'tui.notification_method="osc9"',
      "-c", 'tui.notification_condition="always"',
      ...buildCodexNotifyInjection(hookCommand),
    ],
    env: {},
  };
}

const CodexPayloadSchema = z.object({
  "thread-id": z.string().nullish(),
  thread_id: z.string().nullish(),
});

// SessionStart's stdin (measured): the only Codex hook payload observed to
// carry transcript_path at all — the notify argv (after-agent) and Stop never
// do. Without forwarding it here, a codex session's agentTranscriptPath stays
// unset forever, and shouldArmInterruptConfirm (agent-core.ts) can never arm
// its transcript-interrupt confirmation for it.
const CodexSessionStartPayloadSchema = z.object({
  session_id: z.string().nullish(),
  transcript_path: z.string().nullish(),
});

// Codex's Stop hook stdin (StopCommandInput). last_assistant_message is a Rust
// NullableString — it arrives as null, not absent, so .nullish() is load-bearing:
// .optional() would reject null.
const CodexStopPayloadSchema = z.object({
  last_assistant_message: z.string().nullish(),
});

// Codex's UserPromptSubmit stdin (measured): session_id, turn_id,
// transcript_path, cwd, hook_event_name, model, permission_mode, prompt. Only
// the three read here matter — turn_id correlates nothing on this side (the
// matching Stop is found by session/terminal, not by turn_id).
const CodexUserPromptPayloadSchema = z.object({
  session_id: z.string().nullish(),
  transcript_path: z.string().nullish(),
  prompt: z.string().nullish(),
});

export const events = ["after-agent", "permission-request", "stop", "session-start", "post-tool-use", "user-prompt"] as const;

// Two closers, not one: `after-agent` is the `notify` channel and `stop` is the
// Stop command hook, and codex fires them independently.
export const turnBoundaryEvents = {
  start: ["user-prompt"],
  end: ["after-agent", "stop"],
} as const;

// codex runs `user-prompt` through a fresh PowerShell/sh plus a bridge process,
// measured at 1.7 s after Enter and about 4 s on a session's first prompt,
// where SessionStart runs first.
export const provisionalTurnStart = true;

export const posts = ["/session-title", "/handler-event", "/notify", "/hook-alive", "/turn-activity", "/turn-start"] as const;
export const observation = { notifications: true, titles: true, handler: true, turnStart: true, turnEnd: true, hookAlive: true } as const;

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
      // Older running terminals may still invoke the pre-review hook.
      return [];
    } else if (invocation.event === "post-tool-use") {
      // A sibling tool completing mid-turn is still activity, re-asserting
      // "working" between UserPromptSubmit and Stop the same way Claude's
      // catch-all PostToolUse does.
      if (terminalId) posts.push({ port, path: "/turn-activity", body: { terminalId } });
    } else if (invocation.event === "user-prompt") {
      // A fresh turn began — reset control-plane work status to "working" so a
      // re-prompt of an existing session (the Stop hook already fired
      // task_complete) no longer reads as done/attention. Replaces keystroke
      // inference for codex: see `needsKeystrokeTurnStart` in registry.ts.
      const input = parseOrEmpty(CodexUserPromptPayloadSchema, raw);
      if (terminalId) posts.push({ port, path: "/turn-start", body: { terminalId } });
      posts.push(
        titlePost(port, terminalId, input?.session_id, "codex", {
          ...(namesTheSession(input?.prompt) ? { prompt: input!.prompt } : {}),
          ...(input?.transcript_path ? { transcriptPath: input.transcript_path } : {}),
        }),
      );
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
    } else if (invocation.event === "session-start") {
      if (terminalId) posts.push({ port, path: "/hook-alive", body: { terminalId } });
      const input = parseOrEmpty(CodexSessionStartPayloadSchema, raw);
      if (input?.transcript_path) {
        posts.push(titlePost(port, terminalId, input.session_id, "codex", {
          transcriptPath: input.transcript_path,
        }));
      }
    } else if (terminalId) {
      posts.push({ port, path: "/hook-alive", body: { terminalId } });
    }
  }

  return compact(posts);
}
