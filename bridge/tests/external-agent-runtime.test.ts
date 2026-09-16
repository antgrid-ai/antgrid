import { expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import { serviceAdapter } from "../../packages/antgrid-agents/tests/fixtures/service-adapter";
import { agentHostServices } from "../src/agent-host";
import { SessionManager } from "../src/session-manager";
import { buildAgentCatalog } from "../src/agent-catalog";
import { detectAvailableTools } from "../src/tool-detector";
import { executeHeadless } from "../src/agents/headless";
import { updateSpecFor, execToolUpdate, createToolUpdateChecker } from "../src/update/specs";

test("a public-only service adapter reaches bridge discovery, launch, observation and operations", async () => {
  const directory = mkdtempSync(join(tmpdir(), "antgrid-external-adapter-"));
  let released = 0;
  let ready!: () => void;
  const readiness = new Promise<void>((resolve) => { ready = resolve; });
  const definition = serviceAdapter(() => { released++; });
  const runtime = createAgentRuntime({ host: { ...agentHostServices, stateDirectory: () => directory }, registry: createAgentRegistry([["service", {
    ...definition,
    create(host) {
      const spec = definition.create(host);
      return { ...spec, prepareTerminal: async (request) => {
        const launch = await spec.prepareTerminal!(request);
        return { ...launch, attach: async () => {
          await readiness;
          request.scope?.emit({ type: "session-identity", nativeId: "native" });
          request.scope?.emit({ type: "ready" });
        } };
      } };
    },
  }]]) });
  const running = new Set<string>();
  const prompts: string[] = [];
  const tm = { spawn: (opts: { terminalId: string }) => running.add(opts.terminalId), has: (id: string) => running.has(id),
    kill: (id: string) => running.delete(id), treeKilled: async () => {}, getScrollback: () => null,
    submit: (_id: string, text: string) => prompts.push(text) };
  const sessions = new SessionManager({ agentRuntime: runtime, projectId: "p", projectPath: directory, storeDir: directory,
    terminalManager: tm as never, agentSpec: { name: "service", command: "" }, sendMessage: () => {} });
  try {
    expect(await detectAvailableTools({}, runtime)).toEqual([{ tool: "service", label: "Fixture service", path: undefined }]);
    expect(buildAgentCatalog(runtime)[0]).toMatchObject({ tool: "service", chatCapable: true, handler: { terminal: true, chat: true } });
    const entry = sessions.create("service", { tool: "service", approvalPolicy: "bypass" });
    const start = sessions.start(entry.id, "opening prompt");
    await Promise.resolve();
    expect(prompts).toEqual([]);
    ready();
    await start;
    expect(prompts).toEqual(["opening prompt"]);
    expect(sessions.get(entry.id)?.agentSessionId).toBe("native");
    expect(sessions.handlerAvailability(entry.id).state).toBe("available");
    await sessions.stop(entry.id);
    expect(released).toBe(1);
    const result = await executeHeadless(runtime.get("service")!.headless!.readonly!, "prompt", undefined, { cwd: directory, timeoutMs: 1000 });
    expect(result?.stdout).toBe(directory);
    expect(result?.usage?.outputTokens).toBe(1);
    expect(released).toBe(2);
    const update = updateSpecFor("service", runtime)!;
    expect(await createToolUpdateChecker(update)()).toEqual({ installed: "1.0.0", latest: "2.0.0" });
    expect(await execToolUpdate(update)).toEqual({ exitCode: 0, output: "updated" });
  } finally {
    ready();
    sessions.flushNow();
    rmSync(directory, { recursive: true, force: true });
  }
});
