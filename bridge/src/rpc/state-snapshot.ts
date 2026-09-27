import { z } from "zod";
import type { MessageBus } from "../message-bus";
import type { AbMessage } from "../protocol";

export const StateSnapshotParams = z.object({
  types: z.array(z.string()).min(1),
  // Named types are left out of the answer even when `types` is `["*"]`. A
  // generic filter with no type this bridge is asked to drop: an app sends it
  // to keep a frame only an OLDER bridge caches out of the reply — today that
  // is the whole file tree, which this bridge no longer retains at all. Honour
  // it whatever it names; the app is the one that knows which bridge it is
  // talking to, and a reply it has no handler for is pure cost on the uplink.
  // A bridge that predates this field strips it and answers the heavy way,
  // which is the old behaviour, not a break.
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
 *  this to skip a pull that could not carry it anyway — a pull naming
 *  `handler:status` alone has no business re-deriving every checkout's git
 *  status. Malformed params answer
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
