import { agentRuntime } from "./agent-host";
import { withAgentHost } from "antgrid-agents/host";
import { augmentAgentLaunch as augment } from "antgrid-agents/agent-launch-augmenter";
import { resolveApprovalPolicy as approval } from "antgrid-agents/agent-approval-policy";
import type { AgentRuntime } from "antgrid-agents/runtime";
import type { TerminalObservationAvailability } from "antgrid-agents/contracts";
import { homedir } from "node:os";
import { join } from "node:path";
import { resolveHookCommand, resolveMcpCommand, type ResolveBridgeCommandOptions } from "./hook-command";
import type { AugmentOptions } from "antgrid-agents/agent-launch-augmenter";

export { agentRuntime };
export const AGENTS = agentRuntime.agents;
export const BY_HOOK_NAME = agentRuntime.byHookName;
export const agentSpec = agentRuntime.get;
export const judgeCapable = agentRuntime.judgeCapable;
export const handlerObservable = agentRuntime.handlerObservable;
export const isChatCapableTool = agentRuntime.isChatCapable;
export const prepareTerminalLaunch = agentRuntime.prepareTerminal;
export const resolveStructuredTitle = agentRuntime.resolveStructuredTitle;
export const listKnownTools = () => Object.keys(AGENTS);
export const resolveAgent = (tool: string) => {
  const spec = agentSpec(tool);
  if (!spec?.cli?.bin) throw new Error(`Agent has no CLI executable: ${tool}`);
  return { bin: spec.cli!.bin, args: spec.cli!.args ?? [], hookDir: spec.hookDir?.startsWith("~/") ? join(homedir(), spec.hookDir.slice(2)) : spec.hookDir };
};
export const resolveAgentEnv = (tool: string, abDir = agentRuntime.host.stateDirectory()) => agentSpec(tool)?.cli?.env?.({ abDir }) ?? {};
export const notificationSourceFor = (tool: string) => agentSpec(tool)?.notificationSource ?? "osc";
export const titleSourceFor = (tool: string) => agentSpec(tool)?.titleSource ?? "osc";
export const isOscTitleUnusable = (tool: string | undefined) => !!tool && agentSpec(tool)?.oscTitleUnusable === true;
export const oscTitleForNaming = (tool: string | undefined, raw: string) => tool && isOscTitleUnusable(tool) ? agentSpec(tool)!.label : raw;
export const suppressesOscNotifications = (tool: string, available: boolean | TerminalObservationAvailability | undefined) =>
  notificationSourceFor(tool) === "plugin" && (typeof available === "object" ? available.notifications : available !== false);
export const suppressesOscTitle = (tool: string, available: boolean | TerminalObservationAvailability | undefined) =>
  titleSourceFor(tool) === "structured" && (typeof available === "object" ? available.titles : available !== false);
export const injectsHookAliveProbe = (tool: string) => agentSpec(tool)?.observation?.hookAlive === true;
export const needsKeystrokeTurnStart = (tool: string | undefined) => {
  return !!tool && agentSpec(tool)?.inferTurnStart === true;
};
export const augmentAgentLaunch = (tool: string, { self, ...options }: AugmentOptions & { self?: ResolveBridgeCommandOptions } = {}) =>
  withAgentHost(agentRuntime.host, () => augment(tool, {
    ...options,
    ...(self ? { hookCommand: resolveHookCommand(self), mcpCommand: resolveMcpCommand(self) } : {}),
  }, agentRuntime.get));
export const resolveApprovalPolicy: typeof approval = (tool, mode, policy) => approval(tool, mode, policy, agentRuntime.get);
export function useAgentRuntime<T>(runtime: AgentRuntime, operation: (runtime: AgentRuntime) => T): T {
  return withAgentHost(runtime.host, () => operation(runtime));
}
