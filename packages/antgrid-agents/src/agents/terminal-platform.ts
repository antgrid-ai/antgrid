import { AGENTS } from "./registry";
import type { AgentSpec } from "./types";

export function needsShellForAgentBinary(command: string, agents: Readonly<Record<string, AgentSpec>> = AGENTS): boolean {
  return Object.values(agents).some((spec) => spec.platformIntegration?.matches(command) && spec.platformIntegration.windowsShell);
}

export function prepareAgentBinary(command: string, env: Record<string, string>, agents: Readonly<Record<string, AgentSpec>> = AGENTS): void {
  Object.values(agents).find((spec) => spec.platformIntegration?.matches(command))?.platformIntegration?.prepare(env);
}
