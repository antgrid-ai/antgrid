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
import { readStoreFile, sessionBusMachineDir, writeStoreFile } from "./store-fs";

// Bumped when projectId was added to the row: a pre-move row carried none and
// could not name a stream, so it had to be discarded rather than read as if it
// could. Left at that value now that the FILE itself moves to one machine-level
// path (`sessionBusMachineDir`): the row shape did not change here, and the old
// per-project files simply stop being read — a second bump would only wipe a
// file this version already emptied once.
export const ROUTE_STORE_VERSION = 2;

export const BusRouteSchema = z.object({
  contextId: z.string().min(1).max(200),
  /** The app session's relay slot id. */
  peerId: z.string().min(1).max(400),
  /** The project whose stream carried this exchange in — which socket a reply
   *  leaves on, distinct from the peer's relay slot (route-store.ts:10-15,
   *  above). Load-bearing now that one machine-level table (E9/§5.4) can name
   *  a route for any project this host has open: it is the only thing that
   *  says which project's stream a peer-role dispatch may use. */
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

function routesPath(abDir: string): string {
  return join(sessionBusMachineDir(abDir), "routes.json");
}

/** Read the remembered routes. Entries older than [ttlMs] are dropped here
 *  rather than at first use, so a bridge that comes up after a long stop starts
 *  from the same map it would have converged to. */
export function loadBusRoutes(abDir: string, ttlMs: number, now: number): BusRouteMap {
  const file = readStoreFile<z.infer<typeof BusRoutesFileSchema> | null>(
    routesPath(abDir),
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

/** The file's raw rows, keyed by contextId, with no TTL filtering. An `at` that
 *  reads as lapsed on disk is not proof the route is dead: a bare restamp is
 *  only flushed when a save comes due (`BUS_ROUTE_PERSIST_INTERVAL_MS`), so a
 *  sibling process's row can look expired here while that process is still
 *  carrying frames on it — and this writer has no standing to delete another's
 *  row on a clock it cannot see. The cost is that a dead row rides along in
 *  every save until its own writer drops it (`drops` below) or the file cap
 *  sorts it off the end; nothing ever acts on one, because `loadBusRoutes`
 *  applies the TTL on the way back in. */
function readOnDiskRoutes(abDir: string): Map<string, BusRoute> {
  const file = readStoreFile<z.infer<typeof BusRoutesFileSchema> | null>(
    routesPath(abDir),
    BusRoutesFileSchema,
    null,
  );
  return new Map((file?.routes ?? []).map((r) => [r.contextId, r]));
}

/** Combine on-disk rows with one writer's own table, newest `at` per contextId
 *  wins. A key only one side has is kept as-is — this is what makes the merge
 *  safe for a writer that does not (and cannot) hold the whole machine's
 *  routes: two bridges sharing one `ANTGRID_DIR` each persist only what they
 *  personally learned, and a save must not read the other one's silence on a
 *  context as permission to delete it. */
function mergeRoutes(onDisk: Map<string, BusRoute>, incoming: BusRouteMap): Map<string, BusRoute> {
  const merged = new Map(onDisk);
  for (const [contextId, r] of incoming) {
    const existing = merged.get(contextId);
    if (!existing || r.at >= existing.at) {
      merged.set(contextId, { contextId, peerId: r.peerId, projectId: r.projectId, at: r.at });
    }
  }
  return merged;
}

function writeRoutes(abDir: string, merged: Map<string, BusRoute>): void {
  const dir = sessionBusMachineDir(abDir);
  const rows = [...merged.values()];
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

/**
 * What a writer means to REMOVE from the shared file, as opposed to merely not
 * mentioning. A plain merge cannot express a deletion — a row this writer's
 * table no longer holds reads as "unknown to me", not "gone" — so every drop
 * that has to be durable names itself here.
 *
 * Both kinds delete rows a sibling process may still be using: `contextIds`
 * because the sibling's own row for that context is the same row, `projectId`
 * because the purge runs over the merged set, which by design contains the
 * sibling's rows too. Both are self-healing at the cost of one relearn — the
 * sibling restamps from its own table on its next save — and both are the
 * lesser evil against a forgotten project's routes surviving forever.
 */
export interface BusRouteDrops {
  /** Rows this writer deleted from its own table and needs gone from disk:
   *  a TTL expiry, an LRU eviction, a context whose route lapsed at lookup. */
  contextIds?: Iterable<string>;
  /** Every row naming this project, used by `forgetProjectRoutes` alone. */
  projectId?: string;
}

/**
 * Merge [routes] into whatever is currently on disk and write the result —
 * never a wholesale replace. The file is machine-level (E9/§5.4/C5) and
 * nothing enforces one host process per `ANTGRID_DIR` (the documented
 * dev-stack-beside-installed-bridge setup is exactly this), so a caller's own
 * table is only ITS view, never the machine's whole one; overwriting the file
 * with it would erase every row a sibling process learned since this one last
 * read. Silence about a context is therefore never permission to delete it —
 * [drops] is how a writer says it means one gone, and `BusRouteDrops` carries
 * what that costs a sibling.
 *
 * `drops.contextIds` is applied to the DISK rows BEFORE the merge, while
 * `drops.projectId` is applied to the merged result after it. The difference
 * is deliberate: a context dropped and then relearned before the save comes
 * due is present in [routes], and the incoming row is proof it is live again,
 * so it must win; a forgotten project has nothing that could relearn it in
 * this process at all.
 *
 * The read-merge-write here is not atomic across processes — two saves racing
 * between their own read and write can still lose one side's update — but the
 * failure shrinks from "the whole table" to "one row", and a lost row costs a
 * relearn, never a misdelivery (route-store.ts's header).
 */
export function saveBusRoutes(abDir: string, routes: BusRouteMap, drops?: BusRouteDrops): void {
  const onDisk = readOnDiskRoutes(abDir);
  for (const contextId of drops?.contextIds ?? []) onDisk.delete(contextId);
  const merged = mergeRoutes(onDisk, routes);
  if (drops?.projectId !== undefined) {
    for (const [contextId, r] of merged) {
      if (r.projectId === drops.projectId) merged.delete(contextId);
    }
  }
  writeRoutes(abDir, merged);
}
