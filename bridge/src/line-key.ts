// A join key for one delivery, so the same line can be recognised at each stage
// it passes through — the queue, the drain, the injection and the PTY submit —
// in a log file that never contains the line itself.
//
// This is the whole reason it is a digest and not a prefix: `host.log` is a
// durable file the app tells users to send, on a product whose claim is a
// zero-knowledge relay, and `renderNotify`/`renderReply` put the peer header and
// the sender's summary FIRST — so a "first N characters" key would log the most
// identifying part of a message rather than the least.
//
// Twelve hex characters is a diagnostic key, not a security one: it identifies a
// line among the handful a session handles in a debugging window, and nothing
// anywhere decides anything on it.

import { createHash } from "node:crypto";

export interface LineKey {
  /** First 12 hex characters of the sha-256 of the line. */
  sha: string;
  /** Length in characters. The one thing worth knowing about a body when the
   *  body may not be written down: it is what separates "the wrong text
   *  arrived" from "nothing arrived at all", and it is what a truncation shows
   *  up in. */
  chars: number;
}

/** All a throw from the delivery path may be logged as. Its message is out of
 *  bounds for the same reason the line is: the adapter can reach a model driver,
 *  and a driver that rejects a request often throws with the request echoed back
 *  — the line among it. */
export function errorName(err: unknown): string {
  return err instanceof Error ? err.name : typeof err;
}

export function lineKey(text: string): LineKey {
  return {
    sha: createHash("sha256").update(text, "utf8").digest("hex").slice(0, 12),
    chars: text.length,
  };
}
