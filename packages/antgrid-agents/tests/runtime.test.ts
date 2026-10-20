import { expect, test } from "bun:test";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import type { AgentHostServices, AgentLogger } from "antgrid-agents/host";
import { createAgentRunScope } from "antgrid-agents/contracts";
import { AGENTS } from "../src/agents/registry";
import { NO_HANDOFF_SNAPSHOT } from "../src/agents/fork-handoff";
import type { AgentDefinition } from "antgrid-agents/runtime";
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

test("every registry agent declares a fork snapshot", () => {
  const entries = Object.entries(AGENTS);
  expect(entries.length).toBeGreaterThan(0);
  for (const [id, spec] of entries) {
    expect(typeof spec.fork.snapshot, id).toBe("function");
    expect(spec.fork.snapshot, id).not.toBe(NO_HANDOFF_SNAPSHOT);
  }
});

test("a spec without fork.snapshot is rejected at registration", () => {
  const base = serviceAdapter();
  const definition: AgentDefinition = {
    ...base,
    create(host) {
      const spec = base.create(host);
      const { snapshot: _omitted, ...fork } = spec.fork;
      return { ...spec, fork } as never;
    },
  };
  expect(() => createAgentRuntime({ registry: createAgentRegistry([["service", definition]]), host: host("one") })).toThrow();
});
