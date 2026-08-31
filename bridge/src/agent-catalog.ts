// Thin accessor over the agent registry (./agents/registry), in the same spirit
// as known-agents.ts / agent-resume.ts: one concern, one file, no per-agent
// knowledge of its own.

import { AGENTS, handlerObservable, judgeCapable } from "./agents/registry";
import type { AgentKey, AgentSpec } from "./agents/types";
import type { AgentDescriptor } from "./protocol";

/**
 * The registry projected onto the wire descriptor. Static per bridge build —
 * nothing here reads the filesystem — so it is safe for the app to cache
 * indefinitely and to merge across machines.
 *
 * Iteration order is the registry declaration order, the same order `tools[]`
 * carries: the app's first-installed-agent pick reads position, so the two
 * arrays must agree.
 */
export function buildAgentCatalog(): AgentDescriptor[] {
  return (Object.entries(AGENTS) as [AgentKey, AgentSpec][]).map(([tool, spec]) => ({
    tool,
    label: spec.label,
    chatCapable: spec.driver !== undefined,
    judgeCapable: judgeCapable(tool),
    handler: {
      terminal: handlerObservable(tool, "terminal"),
      chat: handlerObservable(tool, "chat"),
    },
    approvalPolicies: {
      terminal: spec.approvalPolicies.bypass?.terminalArgs ? ["default", "bypass"] : ["default"],
      chat: spec.approvalPolicies.bypass?.chat ? ["default", "bypass"] : ["default"],
    },
    approvalPolicyRisk: spec.approvalPolicies.bypass?.risk,
  }));
}
