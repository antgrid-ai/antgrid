import { agentSpec } from "./agents/registry";
import type { ApprovalPolicy } from "./agents/types";

export function resolveApprovalPolicy(
  tool: string,
  mode: "terminal" | "chat",
  policy: ApprovalPolicy,
): string[] {
  if (policy === "default") return [];
  const bypass = agentSpec(tool)?.approvalPolicies.bypass;
  const supported = mode === "terminal" ? bypass?.terminalArgs !== undefined : bypass?.chat === true;
  if (!supported) throw new Error(`tool "${tool}" does not support bypass approval policy in ${mode} mode`);
  return mode === "terminal" ? [...bypass!.terminalArgs!] : [];
}
