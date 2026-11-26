// This machine's own name, in ONE place.
//
// The name matters because it is read by a human on another machine, and a
// machine that renders under two names reads as two machines. Three surfaces
// carry it today and they must agree: the account-inventory heartbeat
// (`machineName`, which is what fills `InventoryAgent.machineName` and so what
// the app stamps as a peer row's `machineLabel`), `agent:status`
// (`hostMachineName`, which the app's recents cache names a machine from), and
// the session bus's own `SessionMemberRef.machineLabel`, which is what a
// delivery wrapper says on the receiving machine. Computing the same expression
// a fourth time is how the third one drifts from the first two.

import { hostname } from "node:os";

/**
 * What this machine is called.
 *
 * `ANTGRID_HOST_NAME` first so a dev host, a container or a test can name itself
 * something a reader can tell apart from the hostname the OS reports.
 */
export function selfMachineName(): string {
  return process.env.ANTGRID_HOST_NAME ?? hostname();
}

/** `SessionMemberRefSchema.machineLabel`'s bound (`protocol.ts`). */
const MAX_MACHINE_LABEL_CHARS = 120;

/**
 * This machine's label as it rides a bus frame, or undefined when there is
 * nothing to say.
 *
 * Clamped HERE, at the sender, and not at the receiver, because the receiver
 * never gets a chance to refuse it: an inbound bus envelope is admitted by
 * `parseMessageFast` on its type tag alone, so an over-long label is folded,
 * acked and rendered, and then fails `readRecords`' row schema on the next cold
 * load — which drops that row silently and takes the mailbox post and the log
 * entry with it. A length nobody can see is the wrong place to discover a bound.
 */
export function selfMachineLabel(): string | undefined {
  const name = selfMachineName().trim();
  return name ? name.slice(0, MAX_MACHINE_LABEL_CHARS) : undefined;
}
