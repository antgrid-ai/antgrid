import { z } from "zod";
import type { MessageBus } from "../message-bus";
import type { AbMessage } from "../protocol";

export const StateSnapshotParams = z.object({
  types: z.array(z.string()).min(1),
});

export function stateSnapshotHandler(
  bus: MessageBus,
  params: z.infer<typeof StateSnapshotParams>,
): { frames: AbMessage[] } {
  return { frames: bus.getSnapshot(params.types) };
}
