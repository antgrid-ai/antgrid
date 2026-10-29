// SPDX-License-Identifier: MPL-2.0

import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { MEMORY_AGENT_GUIDANCE } from "antgrid-agents/memory-guidance";
import { runHookInvocation, type HookPost } from "../src/hook-runner";

const enabled = { available: true, enabled: true, paused: false, project_paused: false };

function harness(options: {
  agent?: string;
  event?: string;
  source?: string;
  response?: unknown;
  error?: boolean;
  env?: Record<string, string | undefined>;
} = {}) {
  const posts: HookPost[] = [];
  const requests: HookPost[] = [];
  const outputs: string[] = [];
  return {
    posts, requests, outputs,
    run: () => runHookInvocation({ agent: options.agent ?? "codex", event: options.event ?? "session-start" }, {
      env: { ANTGRID_API_PORT: "43123", ANTGRID_TERMINAL_ID: "trusted-session", ANTGRID_RUN_ID: "trusted-run", ANTGRID_MEMORY_MCP: "1", ...options.env },
      readStdin: async () => JSON.stringify({ source: options.source, session_id: "native-session", transcript_path: "/unread/transcript", terminalId: "spoof-session", runId: "spoof-run" }),
      readFile: () => { throw new Error("Hook output must not read a fallback or transcript"); },
      post: async (post) => { posts.push(post); },
      request: async (request) => {
        requests.push(request);
        if (options.error) throw new Error("offline");
        return options.response;
      },
      writeStdout: (output) => { outputs.push(output); },
    }),
  };
}

describe("Codex static memory guidance", () => {
  test.each(["startup", "resume", "clear", "compact", "fork"])("%s uses inherited identity and preserves notifications", async (source) => {
    const h = harness({ source, response: enabled });
    await h.run();
    expect(h.requests).toEqual([{
      port: 43123, path: "/memory/bootstrap", query: { terminalId: "trusted-session" }, body: { runId: "trusted-run" },
    }]);
    expect(h.outputs).toHaveLength(1);
    expect(JSON.parse(h.outputs[0]!)).toEqual({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: MEMORY_AGENT_GUIDANCE } });
    expect(h.outputs[0]).not.toContain("/unread/transcript");
    expect(h.outputs[0]).not.toContain("native-session");
    expect(h.posts.map((post) => post.path)).toEqual(["/hook-alive", "/session-title"]);
  });

  test.each([
    null, {}, { ...enabled, enabled: false }, { ...enabled, paused: true }, { ...enabled, project_paused: true },
    { ...enabled, available: false }, { ...enabled, enabled: "true" },
    { available: true, enabled: true, paused: false },
    { ...enabled, records: [{ content: "must never reach the model" }] },
    { error: { code: "NOT_A_SESSION", message: "stale caller" } },
    { error: { code: "FORBIDDEN", message: "mismatched caller" } },
    { error: { code: "UNAVAILABLE", message: "offline" } },
  ])("refuses unavailable, disabled, paused, invalid or rejected replies %#", async (response) => {
    const h = harness({ response });
    await h.run();
    expect(h.requests).toHaveLength(1);
    expect(h.outputs).toEqual([]);
    expect(h.posts.map((post) => post.path)).toEqual(["/hook-alive", "/session-title"]);
  });

  test("request failure does not suppress existing notifications", async () => {
    const h = harness({ error: true });
    await h.run();
    expect(h.outputs).toEqual([]);
    expect(h.posts.map((post) => post.path)).toEqual(["/hook-alive", "/session-title"]);
  });

  test.each([
    { ANTGRID_API_PORT: undefined }, { ANTGRID_API_PORT: "not-a-port" }, { ANTGRID_API_PORT: "65536" },
    { ANTGRID_TERMINAL_ID: undefined }, { ANTGRID_TERMINAL_ID: " " },
    { ANTGRID_RUN_ID: undefined }, { ANTGRID_RUN_ID: " " },
  ])("missing inherited identity never requests bootstrap %#", async (env) => {
    const h = harness({ response: enabled, env });
    await h.run();
    expect(h.requests).toEqual([]);
    expect(h.outputs).toEqual([]);
  });

  test.each([undefined, "0", ""])("without the registered-server flag (%p) no bootstrap request is made", async (flag) => {
    const h = harness({ response: enabled, env: { ANTGRID_MEMORY_MCP: flag } });
    await h.run();
    expect(h.requests).toEqual([]);
    expect(h.outputs).toEqual([]);
    expect(h.posts.map((post) => post.path)).toEqual(["/hook-alive", "/session-title"]);
  });

  test.each(["user-prompt", "post-tool-use", "stop", "after-agent", "permission-request", "invented"])("other Codex event %s has no bootstrap request", async (event) => {
    const h = harness({ event, response: enabled });
    await h.run();
    expect(h.requests).toEqual([]);
    expect(h.outputs).toEqual([]);
  });

  test.each(["claude", "cursor", "copilot", "opencode", "unknown"])("other provider %s has no stdout request", async (agent) => {
    const h = harness({ agent, response: enabled });
    await h.run();
    expect(h.requests).toEqual([]);
    expect(h.outputs).toEqual([]);
  });
});

test("source hook emits only validated JSON and bounds bootstrap transport", async () => {
  let reply = "enabled";
  let redirected = 0;
  const received: { url: string; body: unknown }[] = [];
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/redirected") { redirected++; return Response.json(enabled); }
    const body = await request.json();
    if (url.pathname !== "/memory/bootstrap") return Response.json({});
    received.push({ url: url.pathname + url.search, body });
    if (reply === "redirect") return new Response(null, { status: 307, headers: { location: "/redirected" } });
    if (reply === "error") return Response.json(enabled, { status: 403 });
    if (reply === "oversized") return new Response(JSON.stringify(enabled) + " ".repeat(1024));
    if (reply === "slow") await Bun.sleep(2500);
    return Response.json(enabled);
  } });
  try {
    for (reply of ["enabled", "error", "oversized", "redirect", "slow"]) {
      const proc = Bun.spawn([process.execPath, join(import.meta.dir, "..", "src", "index.ts"), "hook", "codex", "session-start"], {
        env: { ...process.env, ANTGRID_API_PORT: String(server.port), ANTGRID_TERMINAL_ID: "session-with-?&", ANTGRID_RUN_ID: "run", ANTGRID_MEMORY_MCP: "1" },
        stdin: "pipe", stdout: "pipe", stderr: "pipe",
      });
      proc.stdin.write(JSON.stringify({ source: "startup", session_id: "native" }));
      proc.stdin.end();
      const [code, output, errors] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
      expect(code).toBe(0);
      expect(errors).toBe("");
      if (reply === "enabled") expect(JSON.parse(output)).toEqual({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: MEMORY_AGENT_GUIDANCE } });
      else expect(output).toBe("");
    }
    expect(redirected).toBe(0);
    expect(received).toHaveLength(5);
    for (const request of received) {
      expect(request.url).toBe("/memory/bootstrap?terminalId=session-with-%3F%26");
      expect(request.body).toEqual({ runId: "run" });
    }
  } finally { server.stop(true); }
}, 15_000);

test("a warning logged while the hook runs goes to stderr, never into the agent's stdout", async () => {
  const script = `
    import { runHookCli } from ${JSON.stringify(join(import.meta.dir, "..", "src", "cli", "hook.ts"))};
    import { logger } from ${JSON.stringify(join(import.meta.dir, "..", "src", "logger.ts"))};
    await runHookCli("codex", "session-start", undefined, {
      env: { ANTGRID_API_PORT: "43123", ANTGRID_TERMINAL_ID: "t", ANTGRID_RUN_ID: "r", ANTGRID_MEMORY_MCP: "1" },
      readStdin: async () => "{}",
      readFile: () => "",
      post: async () => { logger.warn("hook post failed"); },
      request: async () => (${JSON.stringify(enabled)}),
      writeStdout: (output) => { process.stdout.write(output); },
    });
  `;
  const proc = Bun.spawn([process.execPath, "-e", script], { stdout: "pipe", stderr: "pipe" });
  const [code, output, errors] = await Promise.all([proc.exited, new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  expect(code).toBe(0);
  expect(JSON.parse(output)).toEqual({ hookSpecificOutput: { hookEventName: "SessionStart", additionalContext: MEMORY_AGENT_GUIDANCE } });
  expect(errors).toContain("hook post failed");
}, 15_000);
