import { join } from "node:path";
import { z } from "zod";
import { atomicWriteFile } from "../../discovery";
import type { HookCommand } from "../../hook-command";
import { logger } from "../../logger";
import { hasFiles } from "../launch-inject";
import { compact, parseOrEmpty, titlePost, type HookInvocation, type HookPost } from "../hook-posts";
import type { HookInjectCtx, HookPostCtx, LaunchAugmentation } from "../types";

const log = logger.child({ component: "agent-launch" });

// The one tool whose whole purpose is to stop and ask the user. Claude renders
// it through the same permission dialog as any other call, so its Notification
// is indistinguishable from an ordinary permission prompt — a PreToolUse
// matcher is the only signal that NAMES the tool, and the only way a terminal
// session can report a question as a question.
const ASK_QUESTION_TOOL = "AskUserQuestion";

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
      // The trio that makes a terminal session's own question visible. The
      // `matcher` is a RegEx over the tool name, so all three run for this one
      // tool and nothing else. The post hooks are not decoration: they carry the
      // same `tool_use_id` back, and on a PTY there is no resolve RPC — that id
      // returning is the only deterministic word that the question is over.
      //
      // BOTH completions have to be registered, because they are alternatives:
      // a question the user escapes out of or denies fires PostToolUseFailure
      // INSTEAD of PostToolUse. One event serves them because nothing downstream
      // wants to tell them apart — the row exists to say the agent is stopped,
      // and it is equally gone either way. Without the failure twin the only
      // thing left to retire it is a turn boundary, and Claude fires neither
      // Stop nor StopFailure on a user interrupt: the session would rest at
      // "needs you" and swallow every later block on that slot as a
      // re-announcement of a prompt that is no longer on screen.
      //
      // None may take `async: true`. A synchronous PreToolUse completes before
      // the dialog is drawn, which is what puts the question on record ahead of
      // the permission Notification Claude schedules seconds later — and that
      // ordering is the whole basis for suppressing the second one.
      PreToolUse: [{ matcher: ASK_QUESTION_TOOL, hooks: [claudeHook(command, "question")] }],
      PostToolUse: [{ matcher: ASK_QUESTION_TOOL, hooks: [claudeHook(command, "question-answered")] }],
      PostToolUseFailure: [{ matcher: ASK_QUESTION_TOOL, hooks: [claudeHook(command, "question-answered")] }],
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
  // PreToolUse/PostToolUse: Claude's own id for THIS tool call, and the only
  // thing correlating the question with the report that answered it — the
  // escalation raised by one is retired by the other. The tool itself is not
  // modelled: the hook's `matcher` is what selects it, so a payload reaching
  // here is already AskUserQuestion's.
  tool_use_id: z.string().nullish(),
  // AskUserQuestion's input, narrowed to what names the block. `options` are
  // deliberately not modelled: the escalation is answered as free text, so the
  // labels would only bloat a loopback POST nobody reads them from.
  tool_input: z.object({
    questions: z.array(z.object({
      question: z.string().nullish(),
      header: z.string().nullish(),
    })).nullish(),
  }).nullish(),
  // Notification only: the CLI's own name for what it is announcing
  // ("permission_prompt", "idle_prompt", …). Absent on an older installed CLI,
  // which is the whole reason the message-text fallback survives below.
  notification_type: z.string().nullish(),
});
type ClaudePayload = z.infer<typeof ClaudePayloadSchema>;

// "user-prompt" (→ /turn-start + /session-title) is Claude-specific: Claude exposes a
// UserPromptSubmit hook that fires before each new turn, and it is the ONLY
// turn-start signal a terminal-mode Claude session has (chat sessions get
// precise `agent:turn-start` frames from their driver instead).
// Codex/Cursor/Copilot expose no pre-turn hook, so their terminal-mode sessions
// infer the start from a submitted keystroke — see `needsKeystrokeTurnStart` in
// ../registry.ts, which reads the `turnBoundaryEvents` declared below. Their
// turn-END hooks still deliver attention/error/done.
//
// "question"/"question-answered" are the AskUserQuestion pair, the second of
// which is raised by either completion hook — the two are alternatives and
// report the same fact. They post only to paths `posts` already declares, and
// neither is a turn boundary — a question is a pause inside a turn, not the end
// of one.
export const events = [
  "session-start", "stop", "stop-failure", "notification", "user-prompt",
  "question", "question-answered",
] as const;

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

// Bounds the loopback POST, not the display. Set to the engine's escalation row
// width, which is a ceiling rather than a parity: the engine clips the COMPOSED
// body ("Agent asks: …"), so a question arriving at this cap is cut a second
// time by the length of that prefix. Raising the constant to make the two cuts
// agree cannot work — it only makes the second one longer.
const MAX_QUESTION_DETAIL_CHARS = 400;

// The tool allows 1-4 questions and only the first is surfaced, mirroring the
// chat backend's read of the identical tool_input. A question with no text of
// its own still names its block through the header the dialog shows above it.
function askedQuestion(input: ClaudePayload): string {
  const asked = input.tool_input?.questions?.[0];
  return (asked?.question ?? asked?.header ?? "").trim().slice(0, MAX_QUESTION_DETAIL_CHARS);
}

// The permission Notification is the ONLY place the CLI says which tool it is
// blocked on, and it says it in a sentence: the hook payload for that event is
// `{message, title, notification_type}` and carries no `tool_name` at all.
// Verified template: `Claude needs your permission to use ${toolName}` — matched
// on the suffix so the product name is free to change.
//
// This is what lets the host tell "the AskUserQuestion we already announced" from
// "a Bash call that needs approval" while both are outstanding on one slot; a
// suppression keyed on the slot alone silences the second. A miss returns
// undefined, which the host reads as "cannot say which prompt this is about" and
// forwards — costing a duplicate push rather than a silenced block.
const PERMISSION_PROMPT_TOOL = /needs your permission to use (\S+)/;

function permissionPromptTool(message: string | null | undefined): string | undefined {
  return message?.match(PERMISSION_PROMPT_TOOL)?.[1];
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
  // Both halves of the question pair need a slot: an escalation nobody can
  // route to a session is not supervision, it is a stuck row.
  if (invocation.event === "question" && terminalId) {
    const detail = askedQuestion(input);
    posts.push({
      port,
      path: "/handler-event",
      body: {
        terminalId,
        agent: "claude",
        event: "question",
        detail,
        // Omitted when absent, never "": the id is what a later report retires
        // this row BY, and the host reads an id-less retraction as "every prompt
        // on this session is gone". Mint and retirement have to spell "no id"
        // the same way or one tool call's completion takes an unrelated row
        // with it.
        ...(input.tool_use_id ? { promptId: input.tool_use_id } : {}),
        // What the host matches the CLI's later permission Notification against,
        // so a DIFFERENT tool blocking on the same slot is still announced. The
        // matcher above is what makes this a fact rather than a guess.
        promptTool: ASK_QUESTION_TOOL,
        transcriptPath: input.transcript_path ?? "",
        sessionId: input.session_id ?? "",
      },
    });
    // Posted whether or not Handler is armed: it is what puts the slot on
    // "needs you" and what says WHAT was asked, and the notification it
    // pre-empts could only say the "Permission needed" every tool call gets.
    // Whether it is also PUSHED is the host's call — an armed session already
    // gets the escalation's push, carrying this same sentence.
    posts.push({
      port,
      path: "/notify",
      body: {
        type: "question",
        terminalId,
        ...(detail ? { message: detail } : {}),
      },
    });
  }
  if (invocation.event === "question-answered" && terminalId) {
    // No /notify: a question that is over is not an alert. This exists to retire
    // the escalation the PreToolUse raised, by the id Claude gave that one tool
    // call — which both completion hooks report, so an answer and an interrupt
    // arrive here identically.
    posts.push({
      port,
      path: "/handler-event",
      body: {
        terminalId,
        agent: "claude",
        event: "prompt_answered",
        // Same spelling the `question` above mints with, for the same reason.
        ...(input.tool_use_id ? { promptId: input.tool_use_id } : {}),
        transcriptPath: input.transcript_path ?? "",
        sessionId: input.session_id ?? "",
      },
    });
  }
  if (invocation.event === "notification") {
    // Three states reach this one hook: a live permission prompt, the generic
    // post-completion idle nudge, and a question — Claude renders
    // AskUserQuestion through its permission dialog, so that one arrives here
    // wearing the permission prompt's clothes. `notification_type` separates
    // the first two exactly; nothing here can single out the third, which is
    // why the question has a producer of its own above.
    //
    // The message-text test is the fallback for an installed CLI old enough to
    // send no `notification_type` at all, and for any value added upstream:
    // guessing from the words is worse than today's behaviour on neither.
    const notificationType = input.notification_type ?? "";
    const isWaitingNudge = notificationType === "idle_prompt" ? true
      : notificationType === "permission_prompt" ? false
      : !!input.message && /waiting/i.test(input.message);
    // Only a block names a tool; the idle nudge is about the session, not about
    // any one call, so asking it for one could only produce a false match.
    const promptTool = isWaitingNudge ? undefined : permissionPromptTool(input.message);
    if (terminalId) {
      posts.push({
        port,
        path: "/handler-event",
        body: {
          terminalId,
          // Still "awaiting_input" for a live permission prompt, not
          // "permission_request": the payload carries no tool_use_id, so an
          // escalation raised from it would have no deterministic retirement
          // signal — the very trap the question hooks exist to avoid.
          agent: "claude",
          event: "awaiting_input",
          transcriptPath: input.transcript_path ?? "",
          sessionId: input.session_id ?? "",
          // The same reading the /notify below branches on, carried so the host's
          // stale-nudge drop cannot classify as an idle nudge the very invocation
          // it is about to record as a live block: this POST is decided before
          // that one has folded into the reduction it reads.
          idleNudge: isWaitingNudge,
          // Carried on both posts of this invocation because the two routes ask
          // the host the same question and must not be answered differently —
          // and this body has no `message` of its own to re-read the tool from.
          ...(promptTool ? { promptTool } : {}),
        },
      });
    }
    posts.push({
      port,
      path: "/notify",
      body: {
        type: isWaitingNudge ? "awaiting_input" : "permission_request",
        ...(terminalId ? { terminalId } : {}),
        ...(input.message ? { message: input.message } : {}),
        ...(promptTool ? { promptTool } : {}),
      },
    });
  }

  return compact(posts);
}
