// SPDX-License-Identifier: MPL-2.0

import { z } from "zod";

export { MEMORY_AGENT_GUIDANCE } from "../assets/memory-guidance";

export const MemoryBootstrapSchema = z.strictObject({
  available: z.literal(true),
  enabled: z.boolean(),
  paused: z.boolean(),
  project_paused: z.boolean(),
});

export type MemoryBootstrap = z.infer<typeof MemoryBootstrapSchema>;
