import { expect, test } from "bun:test";
import { createAgentRuntime } from "antgrid-agents/runtime";
import { createAgentRegistry } from "antgrid-agents/registry";
import { agentHost, type AgentHostServices, type AgentLogger } from "antgrid-agents/host";
import type { AgentDefinition } from "antgrid-agents/runtime";
import type { HandoffSnapshot } from "antgrid-agents/handoff";
import { serviceAdapter } from "./fixtures/service-adapter";

const logger: AgentLogger = { child: () => logger, debug() {}, info() {}, warn() {}, error() {} };
const host: AgentHostServices = {
  logger, stateDirectory: () => "state-dir", hookCommand: () => ({ binary: "unused", preargs: [] }),
  killChildTree: async () => {}, stripInheritedCertOverrides: (env) => env,
};

test("an events parser can call agentHost() throughout the parse", async () => {
  const base = serviceAdapter();
  const definition: AgentDefinition = {
    ...base,
    create(h) {
      const spec = base.create(h);
      return {
        ...spec,
        fork: {
          ...spec.fork,
          events: async (_dir, _manifest, sink) => {
            sink({ kind: "assistant", text: agentHost().stateDirectory(), at: "before" });
            await new Promise((resolve) => setTimeout(resolve, 5));
            await Promise.resolve();
            sink({ kind: "assistant", text: agentHost().stateDirectory(), at: "after" });
          },
        },
      };
    },
  };
  const runtime = createAgentRuntime({ registry: createAgentRegistry([["service", definition]]), host });
  const seen: string[] = [];
  await runtime.get("service")!.fork.events("unused", {} as HandoffSnapshot, (e) => seen.push(`${e.at}:${(e as { text: string }).text}`), new AbortController().signal);
  expect(seen).toEqual(["before:state-dir", "after:state-dir"]);
});

test("a spec without fork.events is rejected at registration", () => {
  const base = serviceAdapter();
  const definition: AgentDefinition = {
    ...base,
    create(h) {
      const spec = base.create(h);
      const { events: _omitted, ...fork } = spec.fork;
      return { ...spec, fork } as never;
    },
  };
  expect(() => createAgentRuntime({ registry: createAgentRegistry([["service", definition]]), host })).toThrow();
});

