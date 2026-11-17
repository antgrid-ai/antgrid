// What this machine decided about each message another machine sent it, so a
// resend (the sender's outbox is at-least-once) is re-acknowledged with the
// original verdict instead of being applied again. A refusal is remembered as
// firmly as an application: a message refused once stays refused, and the pair
// budget it would otherwise be charged against is spent once.
//
// A row lives until the message's own expiry plus the clock skew the opener
// tolerates, which is the last moment the same id could still be accepted as
// fresh. Past that the sender has given up, so forgetting costs nothing.

import { BUS_MAX_PLAINTEXT_BYTES } from "antgrid-wire";
import { BUS_CLOCK_SKEW_MS } from "./seal";
import { MAX_BUS_SEEN } from "./constants";
import { withBusDb } from "./bus-db";
import type { SeenRow, SeenStore } from "./relay-transport";

export type { SeenRow, SeenStore };

/** Prune on every Nth record rather than every one: the table is read and
 *  written on the delivery path and a sweep per row would double its cost. */
const PRUNE_EVERY = 100;

interface Stored {
  outcome: string;
  code: string | null;
  response: string | null;
}

export function openSeenStore(abDir: string, now: () => number = Date.now): SeenStore {
  let recorded = 0;
  return {
    get(from, id) {
      const row = withBusDb(
        abDir,
        (db) =>
          db
            .query("SELECT outcome, code, response FROM bus_seen WHERE from_machine = ? AND id = ?")
            .get(from, id) as Stored | null,
        null,
      );
      if (!row || (row.outcome !== "applied" && row.outcome !== "refused")) return null;
      return {
        outcome: row.outcome,
        ...(row.code === null ? {} : { code: row.code }),
        ...(row.response === null ? {} : { response: row.response }),
      };
    },

    record(from, id, outcome, code, expiresAt, response) {
      const at = now();
      // Capped at the same bound a sealed body obeys, so a response the
      // handler built cannot make this table the place an oversized one lives.
      const capped = response === undefined ? null : response.slice(0, BUS_MAX_PLAINTEXT_BYTES);
      withBusDb(
        abDir,
        (db) => {
          db.query(
            `INSERT INTO bus_seen (from_machine, id, at, expires_at, outcome, code, response)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (from_machine, id) DO UPDATE SET
               at = excluded.at, expires_at = excluded.expires_at, outcome = excluded.outcome,
               code = excluded.code, response = excluded.response`,
          ).run(from, id, at, expiresAt, outcome, code ?? null, capped);
          recorded += 1;
          if (recorded % PRUNE_EVERY !== 0) return;
          db.query("DELETE FROM bus_seen WHERE expires_at + ? < ?").run(BUS_CLOCK_SKEW_MS, at);
          db.query(
            `DELETE FROM bus_seen WHERE rowid IN (
               SELECT rowid FROM bus_seen ORDER BY at DESC LIMIT -1 OFFSET ?)`,
          ).run(MAX_BUS_SEEN);
        },
        undefined,
      );
    },
  };
}
