import { expect, test } from "bun:test";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import type { AgentHostServices, AgentLogger } from "antgrid-agents/host";
import { createAgentRunScope } from "antgrid-agents/contracts";
import { serviceAdapter } from "./fixtures/service-adapter";

const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
function host(name: string): AgentHostServices {
  return { logger, stateDirectory: () => name, hookCommand: () => ({ binary: "unused", preargs: [] }), killChildTree: async () => {}, stripInheritedCertOverrides: (env) => env };
}

test("two runtimes isolate factories, discovery, host services and native identity", async () => {
  const registry = createAgentRegistry([["service", serviceAdapter()]]);
  const first = createAgentRuntime({ registry, host: host("one") });
  const second = createAgentRuntime({ registry, host: host("two") });
  expect(await first.discover("service")).toEqual({ status: "available" });
  expect(await second.discover("service")).toEqual({ status: "available" });
  expect(first.handlerObservable("service", "terminal")).toBe(true);
  expect(first.judgeCapable("service")).toBe(true);
  const identities: string[] = [];
  const context = { sessionId: "slot", projectId: "project", projectPath: "unused", approvalPolicy: "default" as const,
    scope: createAgentRunScope({ runId: "test", isCurrent: () => true, emit: () => {} }),
    send: () => {}, chatAugment: () => ({ args: [], env: {} }), emitUpdateCheck: () => {}, onAgentSession: (id: string) => identities.push(id) };
  const a = first.createDriver("service", context);
  const b = second.createDriver("service", context);
  await Promise.all([a.start(), b.start()]);
  expect(identities).toEqual(["one", "two"]);
  expect((await first.resolveStructuredTitle("fixture-service", { sessionId: "native" }))?.title).toBe("one");
  await Promise.all([a.dispose(), b.dispose()]);
});

test("native fork and approval policy require no argv builders", async () => {
  let released = 0;
  const runtime = createAgentRuntime({ registry: createAgentRegistry([["service", serviceAdapter(() => { released++; })]]), host: host("one") });
  const scope = createAgentRunScope({ runId: "run", isCurrent: () => true, emit: () => {} });
  const launch = await runtime.prepareTerminal({ tool: "service", configured: { name: "service", command: "" },
    conversation: { kind: "fork", sourceSessionId: "native" }, approvalPolicy: "bypass", cwd: "unused", storeDir: "unused", signal: scope.signal, scope });
  expect(launch.env.FIXTURE_POLICY).toBe("bypass");
  expect(runtime.get("service")?.cli).toBeUndefined();
  await scope.dispose();
  expect(released).toBe(1);
});

test("rejects incompatible API registrations before calling their factories", () => {
  const definition = { ...serviceAdapter(), apiVersion: 99 };
  expect(() => createAgentRuntime({ registry: createAgentRegistry([["service", definition]]) as never, host: host("one") })).toThrow("Unsupported agent API");
});
