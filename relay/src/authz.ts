import type { Connection } from "./connections.js";

/**
 * Account-derived routing authorization (spec 2026-07-24 §3.2): both sides
 * proved account identity at hello, so v1 routing reduces to same-account.
 * This is the ONLY place routing authorization lives — future cross-account
 * shares extend this function, nothing else.
 */
export function mayRoute(sender: Connection, target: Connection): boolean {
  const senderUid = sender.claims?.uid;
  return senderUid !== undefined && senderUid === target.claims?.uid;
}
