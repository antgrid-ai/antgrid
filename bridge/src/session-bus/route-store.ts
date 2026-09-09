// Which app session carries a bus context, across a restart.
//
// A bridge cannot dial another bridge, so the carrier that delivered to it is
// its only way back, and that binding is learned from inbound traffic. A fresh
// process has learned nothing — held messages come back off disk and re-arm
// their retries, and every one of them would refuse for want of a route, while
// the other side has no reason to send the frame that would teach it one. The
// exchange then sits until the messages expire.
//
// A relay slot id (`<accountDeviceUuid>#<machineDeviceUuid>`) is a stable
// transport address for one (account device, machine) pair, not a per-connection
// handle, which is what makes a remembered one still correct after both ends
// reconnect. A slot that no longer resolves simply refuses the send, and the
// next inbound frame rebinds the context — so a wrong entry here costs a retry,
// never a misdelivery.

import { join } from "node:path";
import { z } from "zod";
import { MAX_BUS_ROUTES } from "./constants";
import { readStoreFile, sessionBusProjectDir, writeStoreFile } from "./store-fs";

// Bumped for the move to a machine-level table (E9/§5.4): a pre-move row
// carries no projectId and cannot name a stream, so it must be discarded
// rather than read as if it could. The table is still per-project here — the
// version only needs to move once, ahead of the row shape it protects.
export const ROUTE_STORE_VERSION = 2;

export const BusRouteSchema = z.object({
  contextId: z.string().min(1).max(200),
  /** The app session's relay slot id. */
  peerId: z.string().min(1).max(400),
  /** The project whose stream carried this exchange in — which socket a reply
   *  leaves on, distinct from the peer's relay slot (route-store.ts:10-15,
   *  above). Equal to the table's own project while the table stays
   *  per-project; load-bearing once a machine-level table dispatches across
   *  them. */
  projectId: z.string().min(1).max(200),
  /** When this route was last proven by an applied inbound frame. */
  at: z.number().int().nonnegative(),
});
export type BusRoute = z.infer<typeof BusRouteSchema>;

export const BusRoutesFileSchema = z.object({
  version: z.literal(ROUTE_STORE_VERSION),
  routes: z.array(BusRouteSchema).max(MAX_BUS_ROUTES),
});

export type BusRouteMap = Map<string, { peerId: string; projectId: string; at: number }>;

function routesPath(abDir: string, projectId: string): string {
  return join(sessionBusProjectDir(abDir, projectId), "routes.json");
}

/** Read the remembered routes. Entries older than [ttlMs] are dropped here
 *  rather than at first use, so a bridge that comes up after a long stop starts
 *  from the same map it would have converged to. */
export function loadBusRoutes(abDir: string, projectId: string, ttlMs: number, now: number): BusRouteMap {
  const file = readStoreFile<z.infer<typeof BusRoutesFileSchema> | null>(
    routesPath(abDir, projectId),
    BusRoutesFileSchema,
    null,
  );
  const map: BusRouteMap = new Map();
  for (const r of file?.routes ?? []) {
    if (now - r.at >= ttlMs) continue;
    map.set(r.contextId, { peerId: r.peerId, projectId: r.projectId, at: r.at });
  }
  return map;
}

export function saveBusRoutes(abDir: string, projectId: string, routes: BusRouteMap): void {
  const dir = sessionBusProjectDir(abDir, projectId);
  const rows: BusRoute[] = [...routes.entries()].map(([contextId, r]) => ({
    contextId,
    peerId: r.peerId,
    projectId: r.projectId,
    at: r.at,
  }));
  // Freshest kept, oldest FIRST in the file: the cap is reached by a project
  // accumulating contexts over time, so what drops is what nothing has carried
  // in longest — and the reader rebuilds a Map whose iteration order is the
  // eviction order its own cap depends on.
  rows.sort((a, b) => b.at - a.at);
  writeStoreFile(join(dir, "routes.json"), dir, {
    version: ROUTE_STORE_VERSION,
    routes: rows.slice(0, MAX_BUS_ROUTES).reverse(),
  });
}
