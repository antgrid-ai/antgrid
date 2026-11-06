// SPDX-License-Identifier: MPL-2.0

import { z } from "zod";

import { MEMORY_AGENT_GUIDANCE } from "../assets/memory-guidance";

export { MEMORY_AGENT_GUIDANCE, MEMORY_MCP_SERVER, MEMORY_PREAPPROVED_TOOLS } from "../assets/memory-guidance";

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

/** The guidance text when Memory is on and unpaused; otherwise nothing. */
export function memoryGuidanceFor(bootstrap: MemoryBootstrap | undefined): string | undefined {
  return bootstrap?.enabled && !bootstrap.paused && !bootstrap.project_paused ? MEMORY_AGENT_GUIDANCE : undefined;
}
