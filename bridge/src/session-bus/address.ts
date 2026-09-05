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
 * A map key for an address. Never rendered and never parsed back: the separator
 * is a legal character inside every one of the three ids, so this is
 * deliberately one-way. Anything a human reads is built from the labels.
 */
export function addressKey(a: SessionMemberKey): string {
  return `${a.machineId}/${a.projectId}/${a.sessionId}`;
}
