import { agentSpec } from "./agents/registry";
import type { ApprovalPolicy, AgentSpec } from "./agents/types";

export function resolveApprovalPolicy(
  tool: string,
  mode: "terminal" | "chat",
  policy: ApprovalPolicy,
  get: (tool: string) => AgentSpec | undefined = agentSpec,
): string[] {
  if (policy === "default") return [];
  const bypass = get(tool)?.approvalPolicies.bypass;
  const supported = mode === "terminal" ? bypass?.terminal === true : bypass?.chat === true;
  if (!supported) throw new Error(`tool "${tool}" does not support bypass approval policy in ${mode} mode`);
  return mode === "terminal" ? [...get(tool)?.cli?.approvalBypassArgs ?? []] : [];
}
