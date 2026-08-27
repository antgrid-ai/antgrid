import { z } from "zod";
import type { MessageBus } from "../message-bus";
import type { AbMessage } from "../protocol";

export const StateSnapshotParams = z.object({
  types: z.array(z.string()).min(1),
  // Left out of the answer even when `types` is `["*"]`. Lets the app take the
  // one unbounded durable frame — a checkout's whole file tree — in a pull of
  // its own, so a slow or lost tree reply can no longer cost it the
  // few-hundred-byte `agent:status` its terminal is waiting on. A bridge that
  // predates this field strips it and answers the heavy way, which is the
  // old behaviour, not a break.
  exclude: z.array(z.string()).optional(),
});

export type StateSnapshotParamsT = z.infer<typeof StateSnapshotParams>;

export function stateSnapshotHandler(
  bus: MessageBus,
  params: StateSnapshotParamsT,
): { frames: AbMessage[] } {
  return { frames: bus.getSnapshot(params.types, params.exclude) };
}

/** Whether a `state.snapshot` request would carry at least one of [types].
 *  The intercepts that recompute a frame before the RPC reads the cache use
 *  this to skip a pull that could not carry it anyway — a tree-only pull has
 *  no business re-deriving every checkout's status. Malformed params answer
 *  true: the recompute is harmless, and `dispatchRpc` rejects the request
 *  itself. */
export function snapshotAsksFor(params: unknown, types: readonly string[]): boolean {
  const parsed = StateSnapshotParams.safeParse(params ?? {});
  if (!parsed.success) return true;
  const { types: wanted, exclude = [] } = parsed.data;
  const excluded = new Set(exclude);
  const wildcard = wanted.length === 1 && wanted[0] === "*";
  return types.some((type) => wildcard ? !excluded.has(type) : wanted.includes(type));
}
