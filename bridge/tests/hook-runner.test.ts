import { describe, expect, test } from "bun:test";
import { PassThrough, Readable } from "node:stream";
import {
  MAX_HOOK_STDIN_BYTES,
  readHookStdin,
  runHookInvocation,
  type HookPost,
} from "../src/hook-runner";
import { MAX_NOTIFICATION_BODY_LEN } from "../src/transcript-tail";

function harness(opts: {
  agent: string;
  event: string;
  stdin?: string;
  payload?: string;
  env?: Record<string, string | undefined>;
  files?: Record<string, string>;
}) {
  const posts: HookPost[] = [];
  return {
    posts,
    run: () =>
      runHookInvocation(
        { agent: opts.agent, event: opts.event, payload: opts.payload },
        {
          env: {
            ANTGRID_API_PORT: "43123",
            ANTGRID_TERMINAL_ID: "term-1",
            ...opts.env,
          },
          readStdin: async () => opts.stdin ?? "",
          readFile: (path) => {
            const value = opts.files?.[path];
            if (value === undefined) throw new Error("missing");
            return value;
          },
          post: async (post) => {
            posts.push(post);
          },
        },
      ),
  };
}

describe("Claude hooks", () => {
  test("session-start captures session id and transcript", async () => {
    const h = harness({
      agent: "claude",
      event: "session-start",
      stdin: JSON.stringify({ session_id: "s1", transcript_path: "/tmp/t.jsonl", extra: true }),
    });
    await h.run();
    expect(h.posts).toEqual([
      {
        port: 43123,
        path: "/session-title",
        body: { terminalId: "term-1", sessionId: "s1", transcriptPath: "/tmp/t.jsonl", agent: "claude" },
      },
    ]);
  });

  test("user-prompt posts a turn-start and a title request (fresh turn → working)", async () => {
    const h = harness({
      agent: "claude",
      event: "user-prompt",
      stdin: JSON.stringify({ session_id: "s1", transcript_path: "/tmp/t.jsonl", prompt: "hi" }),
    });
    await h.run();
    expect(h.posts).toEqual([
      { port: 43123, path: "/turn-start", body: { terminalId: "term-1" } },
      {
        port: 43123,
        path: "/session-title",
        body: {
          terminalId: "term-1",
          sessionId: "s1",
          agent: "claude",
          prompt: "hi",
          transcriptPath: "/tmp/t.jsonl",
        },
      },
    ]);
  });

  test("stop sends title, completion, and handler events", async () => {
    const h = harness({
      agent: "claude",
      event: "stop",
      stdin: JSON.stringify({ session_id: "s2", transcript_path: "/tmp/stop.jsonl" }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "task_complete", agent: "claude", terminalId: "term-1", transcriptPath: "/tmp/stop.jsonl" } },
      {
        port: 43123,
        path: "/handler-event",
        body: { terminalId: "term-1", agent: "claude", event: "turn_end", transcriptPath: "/tmp/stop.jsonl", sessionId: "s2" },
      },
      {
        port: 43123,
        path: "/session-title",
        body: { terminalId: "term-1", sessionId: "s2", transcriptPath: "/tmp/stop.jsonl", agent: "claude" },
      },
    ]));
  });

  test("permission notification sends handler plus message", async () => {
    const h = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ message: "Claude needs permission", session_id: "s3", transcript_path: "/t" }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "permission_request", terminalId: "term-1", message: "Claude needs permission" } },
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "awaiting_input",
          transcriptPath: "/t", sessionId: "s3", idleNudge: false,
        },
      },
    ]));
  });

  test("a null transcript_path does not drop the whole event", async () => {
    // Rust/serde agents serialize an absent optional field as JSON `null`, not
    // omission. `.optional()` alone rejects null → the parse fails → every post
    // for the event is silently dropped. Guards the `.nullish()` schemas.
    const h = harness({
      agent: "claude",
      event: "stop",
      stdin: JSON.stringify({ session_id: "s4", transcript_path: null }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "task_complete", agent: "claude", terminalId: "term-1" } },
      {
        port: 43123,
        path: "/session-title",
        body: { terminalId: "term-1", sessionId: "s4", agent: "claude" },
      },
    ]));
    expect(h.posts.length).toBe(3);
  });

  test("a missing terminal id omits the field rather than sending an empty string", async () => {
    const h = harness({
      agent: "claude",
      event: "stop",
      stdin: JSON.stringify({ session_id: "s5", transcript_path: "/tmp/t.jsonl" }),
      env: { ANTGRID_TERMINAL_ID: undefined },
    });
    await h.run();
    const notify = h.posts.find((p) => p.path === "/notify");
    expect(notify?.body).toEqual({ type: "task_complete", agent: "claude", transcriptPath: "/tmp/t.jsonl" });
  });

  test("stop-failure maps a rate limit to limit_hit and nothing else", async () => {
    const h = harness({
      agent: "claude",
      event: "stop-failure",
      stdin: JSON.stringify({
        session_id: "s6",
        transcript_path: "/tmp/fail.jsonl",
        hook_event_name: "StopFailure",
        error: "rate_limit",
      }),
    });
    await h.run();
    expect(h.posts).toEqual([
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1",
          agent: "claude",
          event: "limit_hit",
          transcriptPath: "/tmp/fail.jsonl",
          sessionId: "s6",
          errorClass: "rate_limit",
        },
      },
    ]);
  });

  test("stop-failure maps every non-limit error to turn_failed", async () => {
    for (const error of ["overloaded", "server_error", "unknown", "something_new_upstream"]) {
      const h = harness({
        agent: "claude",
        event: "stop-failure",
        stdin: JSON.stringify({ session_id: "s7", transcript_path: "/t", error }),
      });
      await h.run();
      expect(h.posts).toEqual([
        {
          port: 43123,
          path: "/handler-event",
          body: {
            terminalId: "term-1",
            agent: "claude",
            event: "turn_failed",
            transcriptPath: "/t",
            sessionId: "s7",
            errorClass: error,
          },
        },
      ]);
    }
  });

  test("stop-failure reports a fatal error as a plain turn_end, not a transient", async () => {
    // No wait fixes a bad key or a billing hold, so these must reach the judge
    // immediately instead of spending the ceiling on two "continue" nudges.
    for (const error of [
      "authentication_failed", "oauth_org_not_allowed", "billing_error",
      "invalid_request", "model_not_found", "max_output_tokens",
    ]) {
      const h = harness({
        agent: "claude",
        event: "stop-failure",
        stdin: JSON.stringify({ session_id: "s7", transcript_path: "/t", error }),
      });
      await h.run();
      expect(h.posts).toHaveLength(2);
      expect(h.posts[0]!.body).toMatchObject({ event: "turn_end", errorClass: error });
      // StopFailure fires INSTEAD of Stop, so this is the only thing that ever
      // answers the "working" UserPromptSubmit set — without it the session
      // reads as actively working while the agent sits dead at its prompt.
      // Fatal only: a park is already covered by the engine's own push.
      expect(h.posts[1]!.path).toBe("/notify");
      expect(h.posts[1]!.body).toMatchObject({ type: "error", terminalId: "term-1" });
    }
  });

  test("stop-failure without an error field still reports a transient failure", async () => {
    const h = harness({
      agent: "claude",
      event: "stop-failure",
      stdin: JSON.stringify({ session_id: "s8", transcript_path: null, error: null }),
    });
    await h.run();
    expect(h.posts).toEqual([
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1",
          agent: "claude",
          event: "turn_failed",
          transcriptPath: "",
          sessionId: "s8",
          errorClass: "unknown",
        },
      },
    ]);
  });

  test("stop-failure without a terminal id posts nothing", async () => {
    const h = harness({
      agent: "claude",
      event: "stop-failure",
      stdin: JSON.stringify({ session_id: "s9", error: "rate_limit" }),
      env: { ANTGRID_TERMINAL_ID: undefined },
    });
    await h.run();
    expect(h.posts).toEqual([]);
  });

  test("stop-failure stays claude-only — another agent's allowlist drops it", async () => {
    const h = harness({
      agent: "codex",
      event: "stop-failure",
      stdin: JSON.stringify({ error: "rate_limit" }),
    });
    await h.run();
    expect(h.posts).toEqual([]);
  });

  test("waiting notification posts awaiting_input, not permission_request, plus the handler event", async () => {
    const h = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ message: "Claude is waiting for your input" }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "awaiting_input", terminalId: "term-1", message: "Claude is waiting for your input" } },
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "awaiting_input",
          transcriptPath: "", sessionId: "", idleNudge: true,
        },
      },
    ]));
  });

  test("a question tool call posts the question event and its own notification", async () => {
    const h = harness({
      agent: "claude",
      event: "question",
      stdin: JSON.stringify({
        tool_name: "AskUserQuestion",
        tool_use_id: "toolu_1",
        tool_input: { questions: [{ question: "Which env?", options: [{ label: "prod" }] }] },
        session_id: "s9",
        transcript_path: "/t",
      }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "question",
          detail: "Which env?", promptId: "toolu_1", promptTool: "AskUserQuestion",
          transcriptPath: "/t", sessionId: "s9",
        },
      },
      { port: 43123, path: "/notify", body: { type: "question", terminalId: "term-1", message: "Which env?" } },
    ]));
  });

  test("a question payload with no question text still names the block from its header", async () => {
    const h = harness({
      agent: "claude",
      event: "question",
      stdin: JSON.stringify({
        tool_use_id: "toolu_2",
        tool_input: { questions: [{ header: "Deploy target" }] },
      }),
    });
    await h.run();
    expect(h.posts.map((p) => p.path)).toEqual(["/handler-event", "/notify"]);
    expect(h.posts[0]!.body.detail).toBe("Deploy target");
    expect(h.posts[1]!.body.message).toBe("Deploy target");
  });

  test("a question without a terminal id posts nothing", async () => {
    // No slot, no supervision: an escalation nobody can route to a session is a
    // stuck row, not a report.
    const h = harness({
      agent: "claude",
      event: "question",
      stdin: JSON.stringify({ tool_use_id: "toolu_3", tool_input: { questions: [{ question: "?" }] } }),
      env: { ANTGRID_TERMINAL_ID: undefined },
    });
    await h.run();
    expect(h.posts).toEqual([]);
  });

  test("the answered question posts its retraction and no notification", async () => {
    const h = harness({
      agent: "claude",
      event: "question-answered",
      stdin: JSON.stringify({
        tool_name: "AskUserQuestion",
        tool_use_id: "toolu_1",
        tool_response: { answers: {} },
        session_id: "s9",
        transcript_path: "/t",
      }),
    });
    await h.run();
    expect(h.posts).toEqual([
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "prompt_answered",
          promptId: "toolu_1", transcriptPath: "/t", sessionId: "s9",
        },
      },
    ]);
  });

  test("notification_type classifies the nudge and the block without reading the message", async () => {
    // The verdict must no longer hang on the word "waiting": the CLI names what
    // it is announcing, and the two shapes carry whatever text it likes.
    const nudge = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ notification_type: "idle_prompt", message: "anything at all" }),
    });
    await nudge.run();
    expect(nudge.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "awaiting_input", terminalId: "term-1", message: "anything at all" } },
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "awaiting_input",
          transcriptPath: "", sessionId: "", idleNudge: true,
        },
      },
    ]));

    const block = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ notification_type: "permission_prompt", message: "anything at all" }),
    });
    await block.run();
    expect(block.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "permission_request", terminalId: "term-1", message: "anything at all" } },
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "awaiting_input",
          transcriptPath: "", sessionId: "", idleNudge: false,
        },
      },
    ]));
  });

  test("a notification_type the CLI added falls back to the message", async () => {
    // The fallback covers an installed CLI old enough to send no type at all
    // (pinned by the two message-only cases above) AND a value added upstream,
    // where guessing from the words is no worse than what shipped.
    const h = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ notification_type: "agent_needs_input", message: "Claude is waiting for your input" }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/notify", body: { type: "awaiting_input", terminalId: "term-1", message: "Claude is waiting for your input" } },
    ]));
  });

  test("an interrupted question reports the same completion as an answered one", async () => {
    // PostToolUseFailure fires INSTEAD of PostToolUse when the user escapes out
    // of the dialog or denies the call, and Claude fires neither Stop nor
    // StopFailure on an interrupt — so without this event the escalation stands
    // with nothing able to retire it for the rest of the turn.
    const h = harness({
      agent: "claude",
      event: "question-answered",
      stdin: JSON.stringify({
        tool_name: "AskUserQuestion",
        tool_use_id: "toolu_9",
        error: "The user doesn't want to take this action",
        is_interrupt: true,
      }),
    });
    await h.run();
    expect(h.posts).toEqual([
      {
        port: 43123,
        path: "/handler-event",
        body: {
          terminalId: "term-1", agent: "claude", event: "prompt_answered",
          promptId: "toolu_9", transcriptPath: "", sessionId: "",
        },
      },
    ]);
  });

  test("a tool call with no id of its own omits promptId rather than sending an empty one", async () => {
    // "" and absent are different facts downstream: an id-less retraction means
    // EVERY prompt on the session is gone, so a question minted with "" and a
    // completion spelled undefined would take an unrelated row with it.
    const asked = harness({
      agent: "claude",
      event: "question",
      stdin: JSON.stringify({ tool_input: { questions: [{ question: "Which env?" }] } }),
    });
    await asked.run();
    expect(asked.posts[0]!.body).not.toHaveProperty("promptId");

    const answered = harness({ agent: "claude", event: "question-answered", stdin: "{}" });
    await answered.run();
    expect(answered.posts[0]!.body).not.toHaveProperty("promptId");
  });

  test("a permission notification carries the tool its sentence names", async () => {
    // The only place the CLI says WHICH call it is blocked on — the Notification
    // payload is {message, title, notification_type} and nothing else — and what
    // keeps a parallel batch's Bash approval from being swallowed as a
    // re-announcement of the question beside it.
    const h = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({
        notification_type: "permission_prompt",
        message: "Claude needs your permission to use Bash",
      }),
    });
    await h.run();
    const byPath = Object.fromEntries(h.posts.map((post) => [post.path, post.body]));
    expect(byPath["/handler-event"]!.promptTool).toBe("Bash");
    expect(byPath["/notify"]!.promptTool).toBe("Bash");
  });

  test("the idle nudge names no tool, and neither does a sentence that changed shape", async () => {
    // Absent has to mean "cannot say which prompt this is about", which the host
    // answers by forwarding: a wrong tool name would silence a real block.
    const nudge = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ notification_type: "idle_prompt", message: "Claude is waiting for your input" }),
    });
    await nudge.run();
    for (const post of nudge.posts) expect(post.body).not.toHaveProperty("promptTool");

    const reworded = harness({
      agent: "claude",
      event: "notification",
      stdin: JSON.stringify({ notification_type: "permission_prompt", message: "Approve this tool call?" }),
    });
    await reworded.run();
    for (const post of reworded.posts) expect(post.body).not.toHaveProperty("promptTool");
  });
});

describe("Codex hooks", () => {
  test("after-agent accepts the argv payload and posts title plus turn-end", async () => {
    const h = harness({
      agent: "codex",
      event: "after-agent",
      payload: JSON.stringify({ "thread-id": "thread-1" }),
    });
    await h.run();
    expect(h.posts).toEqual(expect.arrayContaining([
      { port: 43123, path: "/session-title", body: { terminalId: "term-1", sessionId: "thread-1", agent: "codex" } },
      { port: 43123, path: "/handler-event", body: { terminalId: "term-1", agent: "codex", event: "turn_end" } },
    ]));
  });

  test("after-agent accepts the underscore thread id alias", async () => {
    const h = harness({ agent: "codex", event: "after-agent", payload: JSON.stringify({ thread_id: "thread-2" }) });
    await h.run();
    expect(h.posts[0]?.body).toMatchObject({ sessionId: "thread-2" });
  });

  test("permission, stop, and session-start map to their fixed routes", async () => {
    const permission = harness({ agent: "codex", event: "permission-request", stdin: "{}" });
    const stop = harness({ agent: "codex", event: "stop", stdin: "{}" });
    const start = harness({ agent: "codex", event: "session-start", stdin: "{}" });
    await Promise.all([permission.run(), stop.run(), start.run()]);
    expect(permission.posts).toEqual([{ port: 43123, path: "/notify", body: { type: "permission_request", terminalId: "term-1" } }]);
    expect(stop.posts).toEqual([{ port: 43123, path: "/notify", body: { type: "task_complete", terminalId: "term-1" } }]);
    expect(start.posts).toEqual([{ port: 43123, path: "/hook-alive", body: { terminalId: "term-1" } }]);
  });

  test("codex stop forwards last_assistant_message as the notification body", async () => {
    const h = harness({
      agent: "codex",
      event: "stop",
      stdin: JSON.stringify({
        session_id: "s1",
        turn_id: "t1",
        transcript_path: null,
        cwd: "/tmp",
        hook_event_name: "Stop",
        model: "gpt-5.6-sol",
        permission_mode: "bypassPermissions",
        stop_hook_active: false,
        last_assistant_message: "Refactored the parser",
      }),
    });
    await h.run();
    expect(h.posts.find((p) => p.path === "/notify")?.body).toEqual({
      type: "task_complete",
      terminalId: "term-1",
      message: "Refactored the parser",
    });
  });

  test("codex stop still notifies when last_assistant_message is null", async () => {
    const h = harness({
      agent: "codex",
      event: "stop",
      stdin: JSON.stringify({ session_id: "s1", last_assistant_message: null }),
    });
    await h.run();
    expect(h.posts.find((p) => p.path === "/notify")?.body).toEqual({
      type: "task_complete",
      terminalId: "term-1",
    });
  });

  test("codex stop caps an overlong message at MAX_NOTIFICATION_BODY_LEN", async () => {
    const h = harness({
      agent: "codex",
      event: "stop",
      stdin: JSON.stringify({ last_assistant_message: "x".repeat(MAX_NOTIFICATION_BODY_LEN + 50) }),
    });
    await h.run();
    const body = h.posts.find((p) => p.path === "/notify")?.body as { message: string };
    expect(body.message).toHaveLength(MAX_NOTIFICATION_BODY_LEN);
  });

  test("codex stop notifies even when its stdin is not valid json", async () => {
    const h = harness({ agent: "codex", event: "stop", stdin: "not json at all" });
    await h.run();
    expect(h.posts.find((p) => p.path === "/notify")?.body).toEqual({
      type: "task_complete",
      terminalId: "term-1",
    });
  });
});

describe("session capture hooks", () => {
  test("Cursor strips a BOM and only notifies for completed stops", async () => {
    const start = harness({ agent: "cursor", event: "session-start", stdin: `\uFEFF${JSON.stringify({ session_id: "cursor-1" })}` });
    const complete = harness({ agent: "cursor", event: "stop", stdin: `\uFEFF${JSON.stringify({ status: "completed" })}` });
    const aborted = harness({ agent: "cursor", event: "stop", stdin: JSON.stringify({ status: "aborted" }) });
    await Promise.all([start.run(), complete.run(), aborted.run()]);
    expect(start.posts[0]?.body).toEqual({ terminalId: "term-1", sessionId: "cursor-1", agent: "cursor" });
    expect(complete.posts).toEqual([{ port: 43123, path: "/notify", body: { type: "task_complete", terminalId: "term-1" } }]);
    expect(aborted.posts).toEqual([]);
  });

  test("Copilot supports session id aliases, title-only stop, and port-file fallback", async () => {
    const dir = "C:/Users/test/.antgrid";
    const h = harness({
      agent: "github-copilot",
      event: "agent-stop",
      stdin: JSON.stringify({ session: { sessionId: "copilot-1" } }),
      env: { ANTGRID_API_PORT: "", ANTGRID_DIR: dir },
      files: { [`${dir}/api.port`]: "43124\n" },
    });
    await h.run();
    expect(h.posts).toEqual([
      {
        port: 43124,
        path: "/session-title",
        body: { terminalId: "term-1", sessionId: "copilot-1", agent: "github-copilot", titleOnly: true },
      },
    ]);
  });
});

describe("fail-open boundaries", () => {
  test("malformed payload, invalid port, missing environment, and unknown event post nothing", async () => {
    const cases = [
      harness({ agent: "claude", event: "session-start", stdin: "not json" }),
      harness({ agent: "claude", event: "stop", stdin: "{}", env: { ANTGRID_API_PORT: "70000" } }),
      harness({ agent: "cursor", event: "stop", stdin: JSON.stringify({ status: "completed" }), env: { ANTGRID_API_PORT: "", ANTGRID_DIR: "" } }),
      harness({ agent: "claude", event: "unknown", stdin: "{}" }),
    ];
    await Promise.all(cases.map((h) => h.run()));
    for (const h of cases) expect(h.posts).toEqual([]);
  });

  test("post failures are swallowed", async () => {
    await expect(
      runHookInvocation(
        { agent: "codex", event: "stop" },
        {
          env: { ANTGRID_API_PORT: "43123" },
          readStdin: async () => "{}",
          readFile: () => "",
          post: async () => { throw new Error("offline"); },
        },
      ),
    ).resolves.toBeUndefined();
  });

  test("posts for one event start concurrently", async () => {
    let started = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => {
      release = resolve;
    });
    await runHookInvocation(
      { agent: "claude", event: "stop" },
      {
        env: { ANTGRID_API_PORT: "43123", ANTGRID_TERMINAL_ID: "term-1" },
        readStdin: async () => JSON.stringify({ session_id: "s1" }),
        readFile: () => "",
        post: async () => {
          started += 1;
          if (started === 3) release();
          await gate;
        },
      },
    );
    expect(started).toBe(3);
  });

  test("stdin reader truncates at the fixed byte limit", async () => {
    const raw = "x".repeat(MAX_HOOK_STDIN_BYTES + 100);
    const value = await readHookStdin(Readable.from([raw]), 500);
    expect(Buffer.byteLength(value)).toBe(MAX_HOOK_STDIN_BYTES);
  });

  test("stdin reader returns at its drain deadline", async () => {
    const stdin = new PassThrough();
    stdin.write("partial");
    expect(await readHookStdin(stdin, 10)).toBe("partial");
    stdin.destroy();
  });
});
