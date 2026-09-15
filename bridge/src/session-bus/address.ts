// A session-bus address is machine + project + session, and nothing shorter
// works: a machine holds several projects and a project several sessions, so two
// peer sessions on one machine are distinguishable only by all three.

import type { SessionMemberKey } from "../protocol";
import { LOCAL_MACHINE_ID } from "./constants";

/**
 * Whether [machineId] names the machine answering as [selfMachineId].
 *
 * [LOCAL_MACHINE_ID] names it too, under whatever network name it later
 * acquires. A bridge with no relay identity stamps its own frames with the
 * sentinel, and those frames are PERSISTED — a mailbox row, a thread row, the
 * log's peer — so on plain equality a pair that exchanged before the control
 * plane came up would stop matching the moment it did, and two sessions in one
 * process would become permanently unreachable to each other over a name only
 * one of them ever saw change.
 *
 * This only ever widens what THIS machine answers for. A frame still has to
 * name a session the bridge actually holds, so the sentinel buys a sender no
 * reach it did not already have.
 */
export function namesMachine(machineId: string, selfMachineId: string): boolean {
  return machineId === selfMachineId || machineId === LOCAL_MACHINE_ID;
}

/**
 * Identity, and only identity. The labels beside an address are display text
 * that changes under a rename, so folding them in would make the same session
 * compare unequal to itself.
 *
 * The strict comparison, for two halves that came out of ONE record on this
 * machine. {@link addressesSameSession} is the one a frame off the wire is
 * matched with, and the difference between them is the whole of the next
 * paragraph.
 */
export function sameAddress(a: SessionMemberKey, b: SessionMemberKey): boolean {
  return a.machineId === b.machineId && a.projectId === b.projectId && a.sessionId === b.sessionId;
}

/**
 * The half of an address a receiver may MATCH a frame on.
 *
 * NOT symmetric: [a] is this machine's own answer for the session and [b] is
 * what the frame claims, which is the only side the local sentinel may appear
 * on. Passing them the other way round would let a machine be reached by the
 * name "local" from anywhere.
 *
 * `projectId` is deliberately not compared, and the machine id is compared
 * through {@link namesMachine} rather than directly — both for the same reason:
 * the two sides of this comparison are copied, not derived, so each can hold a
 * value the other never had and both be right.
 *
 * `projectId` is whatever the sender recorded
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
  return namesMachine(b.machineId, a.machineId) && a.sessionId === b.sessionId;
}

/**
 * A map key for an address. Never rendered and never parsed back: the separator
 * is a legal character inside every one of the three ids, so this is
 * deliberately one-way. Anything a human reads is built from the labels.
 */
export function addressKey(a: SessionMemberKey): string {
  return `${a.machineId}/${a.projectId}/${a.sessionId}`;
}
