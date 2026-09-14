// Thin accessor over the agent registry (./agents/registry), in the same spirit
// as known-agents.ts / agent-resume.ts: one concern, one file, no per-agent
// knowledge of its own.

import { AGENTS, handlerObservable, judgeCapable } from "./agent-runtime";
import type { AgentKey, AgentSpec } from "antgrid-agents/contracts";
import type { AgentDescriptor } from "./protocol";
import { agentRuntime } from "./agent-runtime";
import type { AgentRuntime } from "antgrid-agents/runtime";

/**
 * The registry projected onto the wire descriptor. Static per bridge build —
 * nothing here reads the filesystem — so it is safe for the app to cache
 * indefinitely and to merge across machines.
 *
 * Iteration order is the registry declaration order, the same order `tools[]`
 * carries: the app's first-installed-agent pick reads position, so the two
 * arrays must agree.
 */
export function buildAgentCatalog(runtime: AgentRuntime = agentRuntime): AgentDescriptor[] {
  return Object.entries(runtime.agents).map(([tool, spec]) => ({
    tool,
    label: spec.label,
    chatCapable: spec.driver !== undefined,
    judgeCapable: runtime.judgeCapable(tool),
    handler: {
      terminal: runtime.handlerObservable(tool, "terminal"),
      chat: runtime.handlerObservable(tool, "chat"),
    },
    approvalPolicies: {
      terminal: spec.approvalPolicies.bypass?.terminal ? ["default", "bypass"] : ["default"],
      chat: spec.approvalPolicies.bypass?.chat ? ["default", "bypass"] : ["default"],
    },
    approvalPolicyRisk: spec.approvalPolicies.bypass?.risk,
  }));
}
