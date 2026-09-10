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
//
// This table is MACHINE-level and has more than one writer: two hosts on one
// ANTGRID_DIR is a documented setup (a dev stack beside an installed bridge),
// so a writer holds only ITS OWN view and a row's absence from that view is
// never permission to delete it. That single sentence used to cost a
// read-merge-write on every save, with a race between the read and the rename
// that could lose the other writer's update outright. A row is now written as a
// row: a writer touches exactly the contexts it learned, and says which ones it
// means GONE.

import { z } from "zod";
import { MAX_BUS_ROUTES } from "./constants";
import { withBusDb } from "./bus-db";

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

export type BusRouteMap = Map<string, { peerId: string; projectId: string; at: number }>;

/**
 * Read the remembered routes, freshest {@link MAX_BUS_ROUTES} of them, OLDEST
 * FIRST.
 *
 * The order is not presentation. `SessionBusCoordinator.noteRoute` evicts from
 * the front of a Map that keeps first-insertion order, so the sequence this
 * function returns IS the LRU position a hydrated route gets — hand them back
 * newest-first and the next eviction drops a live route and keeps a dead one,
 * silently, and only after a restart. Gated by "a hydrated table evicts the
 * least recently carried" in session-bus-machine-level.test.ts.
 *
 * Entries older than [ttlMs] are dropped here rather than at first use, so a
 * bridge that comes up after a long stop starts from the same map it would have
 * converged to.
 *
 * A row that does not validate is skipped alone. The JSON store this replaced
 * could only answer a bad file by emptying the WHOLE table — every project's
 * carrier bindings at once, for one malformed row.
 */
export function loadBusRoutes(abDir: string, ttlMs: number, now: number): BusRouteMap {
  return withBusDb(
    abDir,
    (db) => {
      const rows = db
        .query("SELECT contextId, peerId, projectId, at FROM bus_routes WHERE at > ? ORDER BY at DESC, contextId DESC LIMIT ?")
        .all(now - ttlMs, MAX_BUS_ROUTES) as unknown[];
      const map: BusRouteMap = new Map();
      for (const row of rows.reverse()) {
        const parsed = BusRouteSchema.safeParse(row);
        if (!parsed.success) continue;
        const r = parsed.data;
        map.set(r.contextId, { peerId: r.peerId, projectId: r.projectId, at: r.at });
      }
      return map;
    },
    new Map(),
  );
}

/**
 * What a writer means to REMOVE, as opposed to merely not mentioning.
 *
 * Both kinds delete rows a sibling process may still be using: `contextIds`
 * because the sibling's row for that context is the same row, `projectId`
 * because the purge is not scoped to this writer's own view. Both are
 * self-healing at the cost of one relearn — the sibling restamps from its own
 * table on its next save — and both are the lesser evil against a forgotten
 * project's routes surviving forever.
 */
export interface BusRouteDrops {
  /** Rows this writer deleted from its own table and needs gone: a TTL expiry,
   *  an LRU eviction, a context whose route lapsed at lookup. */
  contextIds?: Iterable<string>;
  /** Every row naming this project, used by `forgetProjectRoutes` alone. */
  projectId?: string;
}

/**
 * Write [routes] as rows, and apply [drops].
 *
 * `drops.contextIds` is applied BEFORE the upsert, `drops.projectId` after. The
 * difference is deliberate and survives the move off JSON: a context dropped
 * and then relearned before the save came due is present in [routes], and the
 * incoming row is proof it is live again, so it must win; a forgotten project
 * has nothing that could relearn it in this process at all.
 *
 * The upsert keeps the newer `at` rather than the newer writer. Two hosts on
 * one ANTGRID_DIR both persist only what they personally learned, and the one
 * that saves second must not roll the other's fresher binding backwards.
 *
 * One transaction, so a sibling never reads this writer's table half-applied —
 * which is the guarantee the read-merge-write it replaces could not give at
 * all.
 */
export function saveBusRoutes(abDir: string, routes: BusRouteMap, drops?: BusRouteDrops): void {
  withBusDb(
    abDir,
    (db) => {
      const dropOne = db.query("DELETE FROM bus_routes WHERE contextId = ?");
      const upsert = db.query(
        `INSERT INTO bus_routes (contextId, peerId, projectId, at) VALUES (?, ?, ?, ?)
         ON CONFLICT(contextId) DO UPDATE SET peerId = excluded.peerId, projectId = excluded.projectId, at = excluded.at
         WHERE excluded.at >= bus_routes.at`,
      );
      db.transaction(() => {
        for (const contextId of drops?.contextIds ?? []) dropOne.run(contextId);
        for (const [contextId, r] of routes) upsert.run(contextId, r.peerId, r.projectId, r.at);
        if (drops?.projectId !== undefined) {
          db.query("DELETE FROM bus_routes WHERE projectId = ?").run(drops.projectId);
        }
        // The cap is reached by contexts accumulating over time, so what goes is
        // what nothing has carried in longest. Enforced on write rather than
        // trusted to the reader's LIMIT: an untrimmed table grows without bound
        // for a machine that never restarts.
        db.query(
          "DELETE FROM bus_routes WHERE contextId NOT IN (SELECT contextId FROM bus_routes ORDER BY at DESC, contextId DESC LIMIT ?)",
        ).run(MAX_BUS_ROUTES);
      })();
      return null;
    },
    null,
  );
}
