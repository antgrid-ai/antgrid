import { test, expect } from "bun:test";
import { spawnSync } from "node:child_process";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "..", "plugin", "antigravity", "post-title.js");

// Port 0, then read back what the kernel assigned. A literal port here sits
// inside the Linux ephemeral range (32768-60999), so any other socket this
// suite opens can be handed it first and this server dies EADDRINUSE.
function run(event: string, stdin: string, env: Record<string, string | undefined> = {}) {
  const hits: { path: string; body: string }[] = [];
  const server = Bun.serve({
    port: 0,
    async fetch(req) {
      hits.push({ path: new URL(req.url).pathname, body: await req.text() });
      return new Response("{}");
    },
  });
  const res = spawnSync("node", [SCRIPT, event], {
    input: stdin,
    env: {
      ...process.env,
      ANTGRID_API_PORT: String(server.port),
      ANTGRID_TERMINAL_ID: "t1",
      ...env,
    },
    encoding: "utf8",
  });
  return { res, hits, server };
}

test("PreInvocation posts sessionId + transcriptPath to /session-title, no titleOnly", async () => {
  const { res, server, hits } = run(
    "PreInvocation",
    JSON.stringify({ conversationId: "conv-1", transcriptPath: "C:/t/transcript_full.jsonl" }),
  );
  await Bun.sleep(150);
  server.stop(true);
  expect(res.stdout).toBe("{}");
  expect(hits).toHaveLength(1);
  expect(hits[0]!.path).toBe("/session-title");
  expect(JSON.parse(hits[0]!.body)).toEqual({
    terminalId: "t1",
    sessionId: "conv-1",
    agent: "antigravity",
    transcriptPath: "C:/t/transcript_full.jsonl",
  });
});

test("Stop (clean) posts /session-title with titleOnly and /notify task_complete", async () => {
  const { server, hits } = run("Stop", JSON.stringify({ conversationId: "conv-2" }));
  await Bun.sleep(150);
  server.stop(true);
  expect(hits).toHaveLength(2);
  const title = hits.find((h) => h.path === "/session-title")!;
  const notify = hits.find((h) => h.path === "/notify")!;
  expect(JSON.parse(title.body)).toEqual({
    terminalId: "t1",
    sessionId: "conv-2",
    agent: "antigravity",
    titleOnly: true,
  });
  expect(JSON.parse(notify.body)).toEqual({ type: "task_complete", terminalId: "t1" });
});

test("Stop with a real error posts /session-title but skips /notify", async () => {
  const { server, hits } = run(
    "Stop",
    JSON.stringify({ conversationId: "conv-3", error: "something failed" }),
  );
  await Bun.sleep(150);
  server.stop(true);
  expect(hits).toHaveLength(1);
  expect(hits[0]!.path).toBe("/session-title");
});

test("missing conversationId posts nothing", async () => {
  const { server, hits } = run("PreInvocation", JSON.stringify({ transcriptPath: "x" }));
  await Bun.sleep(150);
  server.stop(true);
  expect(hits).toHaveLength(0);
});

test("missing ANTGRID_TERMINAL_ID posts nothing and never throws", async () => {
  const { res, server, hits } = run(
    "PreInvocation",
    JSON.stringify({ conversationId: "conv-4" }),
    { ANTGRID_TERMINAL_ID: "" },
  );
  await Bun.sleep(150);
  server.stop(true);
  expect(res.status).toBe(0);
  expect(hits).toHaveLength(0);
});

test("garbage stdin on PreInvocation never throws and posts nothing", async () => {
  const { res, server, hits } = run("PreInvocation", "not json");
  await Bun.sleep(150);
  server.stop(true);
  expect(res.status).toBe(0);
  expect(hits).toHaveLength(0);
});

test("garbage stdin on Stop still fires /notify (it doesn't depend on conversationId)", async () => {
  const { res, server, hits } = run("Stop", "not json");
  await Bun.sleep(150);
  server.stop(true);
  expect(res.status).toBe(0);
  expect(hits).toHaveLength(1);
  expect(hits[0]!.path).toBe("/notify");
});

test("snake_case conversation_id/transcript_path fallback is honored", async () => {
  const { server, hits } = run(
    "PreInvocation",
    JSON.stringify({ conversation_id: "conv-5", transcript_path: "C:/t/x.jsonl" }),
  );
  await Bun.sleep(150);
  server.stop(true);
  expect(hits).toHaveLength(1);
  expect(JSON.parse(hits[0]!.body)).toEqual({
    terminalId: "t1",
    sessionId: "conv-5",
    agent: "antigravity",
    transcriptPath: "C:/t/x.jsonl",
  });
});
