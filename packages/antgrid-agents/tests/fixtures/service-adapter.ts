import type { AgentDefinition } from "antgrid-agents/runtime";
import type { AgentSpec } from "antgrid-agents/contracts";

/** A service invocation fixture that deliberately has no agent executable or argv builders. */
export function serviceAdapter(onRelease: () => void = () => {}): AgentDefinition {
  return {
    apiVersion: 1,
    hookName: "fixture-service",
    create(host): AgentSpec {
      return {
        label: "Fixture service", hookName: "fixture-service", hookDir: null,
        notificationSource: "plugin", titleSource: "structured",
        approvalPolicies: { bypass: { terminal: true, chat: true, risk: "bypasses-approvals" } },
        conversations: { terminal: ["fresh", "resume", "fork"], chat: ["fresh", "resume"] },
        observation: { notifications: true, titles: true, handler: true, turnStart: true, turnEnd: true, hookAlive: false },
        discover: async () => ({ status: "available" }),
        fork: { kind: "native-fork", handoff: async () => "fixture context" },
        prepareTerminal: async (request) => {
          request.scope?.registerCleanup(onRelease);
          return {
            command: process.execPath, invocationKind: "exec", args: [], env: { FIXTURE_POLICY: request.approvalPolicy },
            resumed: request.conversation.kind === "resume", promptDelivery: "buffered",
            attach: async (_terminal, scope) => { scope.emit({ type: "ready" }); },
          };
        },
        driver: (context) => ({
          start: async () => { context.onAgentSession(host.stateDirectory()); },
          prompt: async () => {}, cancel: async () => false, setConfig: () => {},
          resolvePermission: () => {}, resolveQuestion: () => {}, dispose: onRelease,
        }),
        resolveTitle: async () => ({ title: host.stateDirectory(), kind: "manual" }),
        headless: { readonly: { noHistory: "stateless", run: async ({ scope }) => {
          scope.registerCleanup(onRelease);
          return { text: host.stateDirectory(), usage: { outputTokens: 1 } };
        } } },
        update: {
          check: async () => ({ installed: "1.0.0", latest: "2.0.0" }),
          apply: async () => ({ exitCode: 0, output: "updated" }),
        },
      };
    },
  };
}
