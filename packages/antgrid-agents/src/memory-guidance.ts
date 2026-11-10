// SPDX-License-Identifier: MPL-2.0

import { z } from "zod";

import { MEMORY_AGENT_GUIDANCE } from "../assets/memory-guidance";
import type { HookStdoutProfile } from "./agents/hook-posts";

export {
  MEMORY_AGENT_GUIDANCE, MEMORY_MCP_SERVER, MEMORY_PREAPPROVED_TOOLS, MEMORY_SERVER_INSTRUCTIONS, MEMORY_SESSION_NOTICE,
} from "../assets/memory-guidance";

export const MemoryBootstrapSchema = z.strictObject({
  available: z.literal(true),
  enabled: z.boolean(),
  paused: z.boolean(),
  project_paused: z.boolean(),
});

export type MemoryBootstrap = z.infer<typeof MemoryBootstrapSchema>;

/** Keeps only the four settings flags of a memory status result, so nothing
 *  stored or service-side can reach provider instructions through it. */
export function memoryBootstrapFrom(status: Readonly<Record<string, unknown>>): MemoryBootstrap | undefined {
  const parsed = MemoryBootstrapSchema.safeParse({
    available: status.available, enabled: status.enabled,
    paused: status.paused, project_paused: status.project_paused,
  });
  return parsed.success ? parsed.data : undefined;
}

/** Set in a launch's env when its MCP profile really registered the Memory
 *  server; hook scripts in the agent's process read it. */
export const MEMORY_MCP_ENV = "ANTGRID_MEMORY_MCP";

export function memoryRegistered(env: Readonly<Record<string, string | undefined>>): boolean {
  return env[MEMORY_MCP_ENV] === "1";
}

/** `guidance` when Memory is on and unpaused; otherwise nothing. */
export function memoryGuidanceFor(bootstrap: MemoryBootstrap | undefined, guidance: string = MEMORY_AGENT_GUIDANCE): string | undefined {
  return bootstrap?.enabled && !bootstrap.paused && !bootstrap.project_paused ? guidance : undefined;
}

/** A SessionStart hook that asks the bridge whether Memory is on right now and
 *  only then hands the agent `guidance`. The reply is reduced to the four flags
 *  and the output is this fixed text, so nothing stored reaches the model. */
export function memorySessionStartOutput(guidance: string): HookStdoutProfile {
  return {
    events: ["session-start"],
    when: memoryRegistered,
    request: ({ port, terminalId, runId }) => ({
      port,
      path: "/memory/bootstrap",
      query: { terminalId },
      body: { runId },
    }),
    formatResponse(response) {
      const parsed = MemoryBootstrapSchema.safeParse(response);
      const additionalContext = memoryGuidanceFor(parsed.success ? parsed.data : undefined, guidance);
      return additionalContext ? { hookSpecificOutput: { hookEventName: "SessionStart", additionalContext } } : null;
    },
    outputSchema: z.strictObject({
      hookSpecificOutput: z.strictObject({
        hookEventName: z.literal("SessionStart"),
        additionalContext: z.literal(guidance),
      }),
    }),
  };
}
