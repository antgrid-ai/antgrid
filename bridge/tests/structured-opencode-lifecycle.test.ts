import { expect, test } from "bun:test";
import { StructuredAgentManager } from "../src/structured/structured-manager";
import { createDriver } from "../../packages/antgrid-agents/src/agents/opencode/driver";
import { spawnOpencode } from "../../packages/antgrid-agents/src/agents/opencode/spawn";
import { withAgentHost, type AgentHostServices, type AgentLogger } from "../../packages/antgrid-agents/src/host";

const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
const readyServer = `
  const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch(request) {
    const path = new URL(request.url).pathname;
    if (path === "/api/info") return Response.json({ version: "2.2.5" });
    if (path === "/api/session") return Response.json({ data: { id: "replacement" } });
    if (path === "/api/event") return new Response("", { headers: { "Content-Type": "text/event-stream" } });
    return Response.json({ data: [] });
  } });
  console.log("server listening on http://127.0.0.1:" + server.port);
`;

test("OpenCode resume rejects an unsupported runtime and can retry after upgrading", async () => {
  let spawns = 0;
  let kills = 0;
  const sessions: string[] = [];
  const host: AgentHostServices = {
    logger, stateDirectory: () => "unused", hookCommand: () => ({ binary: "unused", preargs: [] }),
    stripInheritedCertOverrides: (env) => env,
    killChildTree: async (child) => { kills++; child.kill(); },
  };
  await withAgentHost(host, async () => {
    const manager = new StructuredAgentManager({
      sendMessage() {}, onAgentSession: (_id, nativeId) => sessions.push(nativeId),
      driverFactory: (sessionId, _tool, send, _resume, approvalPolicy, run) => createDriver({
        sessionId, projectId: "project", projectPath: process.cwd(), approvalPolicy: approvalPolicy!,
        scope: run!.scope, send, onAgentSession: run!.onAgentSession, emitUpdateCheck() {},
        chatAugment: () => ({ args: [], env: {} }),
      }, (opts) => spawnOpencode({ ...opts, command: process.execPath,
        prefixArgs: ["-e", ++spawns === 1 ? readyServer.replace("2.2.5", "1.19.5") : readyServer],
      })),
    });
    const options = { sessionId: "same-session", tool: "opencode", resumeId: "ses_existing" };
    try {
      await expect(manager.startChat(options)).rejects.toThrow("OpenCode 2.0.0 or later is required (found 1.19.5). Run opencode upgrade --major and retry.");
      expect(sessions).toEqual([]);
      expect(kills).toBe(1);
      expect(await manager.startChat(options)).toBe("ready");
      expect(sessions).toEqual(["ses_existing"]);
      expect(spawns).toBe(2);
      await manager.stopChat(options.sessionId);
      expect(kills).toBe(2);
    } finally { await manager.disposeAll(); }
  });
});

test.each([false, true])("OpenCode startup cancellation preserves restart safety (cleanup fails: %s)", async (cleanupFails) => {
  let releaseCleanup!: () => void;
  const cleanupGate = new Promise<void>((resolve) => { releaseCleanup = resolve; });
  let notifyCleanup!: () => void;
  const cleanupStarted = new Promise<void>((resolve) => { notifyCleanup = resolve; });
  let spawns = 0;
  let kills = 0;
  const sessions: string[] = [];
  // The same message as cancellation ensures teardown classification is not textual.
  const cleanupError = new Error("OpenCode startup cancelled");
  const host: AgentHostServices = {
    logger, stateDirectory: () => "unused", hookCommand: () => ({ binary: "unused", preargs: [] }),
    stripInheritedCertOverrides: (env) => env,
    killChildTree: async (child) => {
      kills++;
      if (kills === 1) {
        notifyCleanup();
        await cleanupGate;
        child.kill();
        if (cleanupFails) throw cleanupError;
      } else child.kill();
    },
  };
  await withAgentHost(host, async () => {
    const manager = new StructuredAgentManager({
      sendMessage: () => {}, onAgentSession: (_id, nativeId) => sessions.push(nativeId),
      driverFactory: (sessionId, _tool, send, _resume, approvalPolicy, run) => createDriver({
        sessionId, projectId: "project", projectPath: process.cwd(), approvalPolicy: approvalPolicy!,
        scope: run!.scope, send, onAgentSession: run!.onAgentSession, emitUpdateCheck: () => {},
        chatAugment: () => ({ args: [], env: {} }),
      }, (opts) => {
        spawns++;
        return spawnOpencode({ ...opts, command: process.execPath,
          prefixArgs: ["-e", spawns === 1 ? "setInterval(() => {}, 1000)" : readyServer],
        });
      }),
    });
    const first = manager.startChat({ sessionId: "same-session", tool: "opencode" });
    const stop = manager.stopChat("same-session").then(() => undefined, (error: unknown) => error);
    const replacement = manager.startChat({ sessionId: "same-session", tool: "opencode" })
      .then((outcome) => outcome, (error: unknown) => error);
    try {
      await cleanupStarted;
      expect(spawns).toBe(1);
      releaseCleanup();
      expect(await first).toBe("cancelled");
      if (cleanupFails) {
        expect(await stop).toBeInstanceOf(AggregateError);
        expect((await stop as AggregateError).errors).toContain(cleanupError);
        expect(await replacement).toBe(await stop);
        await expect(manager.startChat({ sessionId: "same-session", tool: "opencode" })).rejects.toThrow(cleanupError.message);
        expect(spawns).toBe(1);
      } else {
        expect(await stop).toBeUndefined();
        expect(await replacement).toBe("ready");
        expect(spawns).toBe(2);
        expect(sessions).toEqual(["replacement"]);
        await manager.stopChat("same-session");
        expect(kills).toBe(2);
      }
    } finally {
      releaseCleanup();
      await Promise.allSettled([first, stop, replacement, manager.disposeAll()]);
    }
  });
});
