import { join } from "node:path";
import { z } from "zod";
import { atomicWriteFile } from "../../discovery";
import type { HookCommand } from "../../hook-command";
import { logger } from "../../logger";
import { hasFiles } from "../launch-inject";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const log = logger.child({ component: "agent-launch" });

function claudeHook(command: HookCommand, event: string) {
  return {
    type: "command",
    command: command.binary,
    args: [...command.preargs, "claude", event],
    timeout: 5,
  };
}

function materializeClaudePlugin(
  abDir: string,
  command: HookCommand,
): string | null {
  const targetDir = join(abDir, "plugin", "claude");
  const manifestPath = join(targetDir, ".claude-plugin", "plugin.json");
  const hooksPath = join(targetDir, "hooks", "hooks.json");
  const manifest = {
    name: "antgrid-session-namer",
    version: "0.1.0",
    description: "Reports agent lifecycle events to the Antgrid bridge.",
  };
  const hooks = {
    hooks: {
      SessionStart: [{ hooks: [claudeHook(command, "session-start")] }],
      Stop: [{ hooks: [claudeHook(command, "stop")] }],
      // A turn that died on a provider fault fires StopFailure INSTEAD of Stop,
      // so without this an armed Handler sees nothing for the whole limit window.
      StopFailure: [{ hooks: [claudeHook(command, "stop-failure")] }],
      Notification: [{ hooks: [claudeHook(command, "notification")] }],
      // A fresh turn: resets control-plane work status to "working" so a
      // re-prompt of an existing session (the Stop hook already fired
      // task_complete) no longer reads as done/attention. See hook-runner's
      // "user-prompt" event → POST /turn-start.
      UserPromptSubmit: [{ hooks: [claudeHook(command, "user-prompt")] }],
    },
  };
  try {
    atomicWriteFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
    atomicWriteFile(hooksPath, `${JSON.stringify(hooks, null, 2)}\n`);
  } catch (err) {
    log.warn("failed to materialize Claude plugin: %s", err);
  }
  return hasFiles([manifestPath, hooksPath]) ? targetDir : null;
}

export function inject({ abDir, hookCommand }: HookInjectCtx): LaunchAugmentation {
  const pluginDir = materializeClaudePlugin(abDir, hookCommand);
  return pluginDir
    ? { args: ["--plugin-dir", pluginDir], env: {}, notificationsInjected: true }
    : { args: [], env: {}, notificationsInjected: false };
}

const ClaudePayloadSchema = z.object({
  session_id: z.string().nullish(),
  transcript_path: z.string().nullish(),
  message: z.string().nullish(),
  // UserPromptSubmit only: the text the user just submitted. Verified against
  // the shipped CLI, whose hook input for that event is
  // `{hook_event_name:"UserPromptSubmit", prompt, session_title, ...}`.
  prompt: z.string().nullish(),
  // StopFailure only. Left a bare string rather than the CLI's enum so a value
  // added upstream still classifies (as a transient) instead of failing the
  // parse and dropping the event.
  error: z.string().nullish(),
});

// "user-prompt" (→ /turn-start + /session-title) is Claude-specific: Claude exposes a
// UserPromptSubmit hook that fires before each new turn, and it is the ONLY
// turn-start signal a terminal-mode Claude session has (chat sessions get
// precise `agent:turn-start` frames from their driver instead).
// Codex/Cursor/Copilot expose no pre-turn hook, so their terminal-mode sessions
// infer the start from a submitted keystroke — see `needsKeystrokeTurnStart` in
// ../registry.ts, which reads the `turnBoundaryEvents` declared below. Their
// turn-END hooks still deliver attention/error/done.
export const events = ["session-start", "stop", "stop-failure", "notification", "user-prompt"] as const;

// "stop-failure" is deliberately not an `end`: it posts a turn-end notify only
// on the fatal classes, and claude never infers a turn start anyway.
export const turnBoundaryEvents = {
  start: ["user-prompt"],
  end: ["stop"],
} as const;

export const posts = ["/session-title", "/turn-start", "/notify", "/handler-event"] as const;

// StopFailure reasons no amount of waiting fixes. They take the ordinary
// turn_end path so the judge escalates at once, matching what the chat-side
// classifier does with the same categories — parking them instead would burn
// the transient ceiling on two useless "continue" nudges first.
const CLAUDE_FATAL_STOP_ERRORS = new Set([
  "authentication_failed", "oauth_org_not_allowed", "billing_error",
  "invalid_request", "model_not_found", "max_output_tokens",
]);

// Anything unrecognized is treated as transient: a value added upstream should
// cost a backoff, not an immediate page.
function claudeStopFailureEvent(errorClass: string): "limit_hit" | "turn_failed" | "turn_end" {
  if (errorClass === "rate_limit") return "limit_hit";
  return CLAUDE_FATAL_STOP_ERRORS.has(errorClass) ? "turn_end" : "turn_failed";
}

// A submission the model can name a task from. A slash command is the user
// invoking a command, not describing what they want done — "/clear", "/commit"
// and their arguments name the command, so a title generated from one describes
// the tool rather than the session, and the attempt it spends is gone.
// Withholding `prompt` does not drop the post: it falls through to the on-disk
// read, which is what a session without a pre-turn hook already does.
function namesTheSession(prompt: string | null | undefined): boolean {
  const text = prompt?.trim();
  return !!text && !text.startsWith("/");
}

export async function toPosts(
  invocation: HookInvocation,
  { port, terminalId, readStdin }: HookPostCtx,
): Promise<HookPost[]> {
  const posts: Array<HookPost | null> = [];
  const input = parseOrEmpty(ClaudePayloadSchema, await readStdin());
  if (!input) return [];
  if (invocation.event === "session-start" || invocation.event === "stop") {
    posts.push(
      titlePost(port, terminalId, input.session_id, "claude", {
        // Omitted when absent, never "": setAgentSession falls back to the path
        // it already holds only for a NULLISH one, so an empty string overwrites
        // it — and this post repeats for the life of the session, so a single
        // report without a path would cost the handler's judge and the resume
        // preflight the real one.
        ...(input.transcript_path ? { transcriptPath: input.transcript_path } : {}),
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
    // Name the session from the prompt the user just submitted. This is the
    // whole reason Claude's naming does not wait for the turn to end, and it is
    // Claude-only because no other agent exposes a pre-turn hook — the rest
    // reach the same code from their turn-END post, minutes later on a real
    // task. The bridge treats `prompt` as "name this now", so it must not ride
    // any other event.
    posts.push(
      titlePost(port, terminalId, input.session_id, "claude", {
        ...(namesTheSession(input.prompt) ? { prompt: input.prompt } : {}),
        ...(input.transcript_path ? { transcriptPath: input.transcript_path } : {}),
      }),
    );
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
  if (invocation.event === "stop-failure" && terminalId) {
    const errorClass = input.error || "unknown";
    const event = claudeStopFailureEvent(errorClass);
    posts.push({
      port,
      path: "/handler-event",
      body: {
        terminalId,
        agent: "claude",
        event,
        transcriptPath: input.transcript_path ?? "",
        sessionId: input.session_id ?? "",
        errorClass,
      },
    });
    // StopFailure fires INSTEAD of Stop, so nothing else ever answers the
    // "working" that UserPromptSubmit set — the session would read as actively
    // working while the agent sits dead at its prompt. Only the fatal classes:
    // they never park, so the engine sends no push of its own, whereas a park IS
    // covered (once, on the first park of an episode) and must not be re-alerted
    // here.
    if (event === "turn_end") {
      posts.push({
        port,
        path: "/notify",
        body: {
          type: "error",
          ...(terminalId ? { terminalId } : {}),
          ...(input.message ? { message: input.message } : {}),
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

  return compact(posts);
}
