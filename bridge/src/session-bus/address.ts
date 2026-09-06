// A session-bus address is machine + project + session, and nothing shorter
// works: a machine holds several projects and a project several sessions, so two
// peer sessions on one machine are distinguishable only by all three.

import type { SessionMemberKey } from "../protocol";

/**
 * Identity, and only identity. The labels beside an address are display text
 * that changes under a rename, so folding them in would make the same session
 * compare unequal to itself.
 *
 * `SessionManager.sameMember` delegates here so a member the manager released
 * and a task the bus addressed can never disagree about who they mean.
 */
export function sameAddress(a: SessionMemberKey, b: SessionMemberKey): boolean {
  return a.machineId === b.machineId && a.projectId === b.projectId && a.sessionId === b.sessionId;
}

/**
 * The half of an address a receiver may MATCH a frame on.
 *
 * `projectId` is deliberately not compared. It is whatever the sender recorded
 * when it joined, and one checkout can be open as more than one project — a
 * managed worktree opened in its own right hashes to an id of its own — so two
 * machines can hold different project ids for the same session and both be
 * right. Machine and session are copied between the two sides rather than
 * derived on each, and a session id is unique on the machine that minted it, so
 * together they are the whole of the identity a receiver can verify. Comparing
 * the project id too is what silently strands a membership: every frame is
 * refused, forever, over a label.
 *
 * {@link sameAddress} stays strict and stays the rule for a member the app names
 * on this bridge's OWN row — both sides of that comparison come from one record,
 * so they cannot legitimately differ.
 */
export function addressesSameSession(a: SessionMemberKey, b: SessionMemberKey): boolean {
  return a.machineId === b.machineId && a.sessionId === b.sessionId;
}

/**
 * A map key for an address. Never rendered and never parsed back: the separator
 * is a legal character inside every one of the three ids, so this is
 * deliberately one-way. Anything a human reads is built from the labels.
 */
export function addressKey(a: SessionMemberKey): string {
  return `${a.machineId}/${a.projectId}/${a.sessionId}`;
}
