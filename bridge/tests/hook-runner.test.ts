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

  test("user-prompt posts a turn-start (fresh turn → working)", async () => {
    const h = harness({
      agent: "claude",
      event: "user-prompt",
      stdin: JSON.stringify({ session_id: "s1", transcript_path: "/tmp/t.jsonl", prompt: "hi" }),
    });
    await h.run();
    expect(h.posts).toEqual([
      { port: 43123, path: "/turn-start", body: { terminalId: "term-1" } },
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
        body: { terminalId: "term-1", agent: "claude", event: "awaiting_input", transcriptPath: "/t", sessionId: "s3" },
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
        body: { terminalId: "term-1", sessionId: "s4", transcriptPath: "", agent: "claude" },
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
      expect(h.posts).toHaveLength(1);
      expect(h.posts[0]!.body).toMatchObject({ event: "turn_end", errorClass: error });
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
        body: { terminalId: "term-1", agent: "claude", event: "awaiting_input", transcriptPath: "", sessionId: "" },
      },
    ]));
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
