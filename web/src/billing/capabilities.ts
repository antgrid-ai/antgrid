// web/src/billing/capabilities.ts

// Capabilities: what a plan or a negotiated contract unlocks, beyond the numeric
// limits already snapshotted onto the subscription. This file is the ONE place a
// capability name exists — naming a new one is a deliberate edit to
// {@link CapabilitiesSchema} here, and every consumer asks the same predicate. A
// `caps.sso === true` written at a call site is exactly the drift this exists to
// prevent.
//
// The alternative was a boolean column per feature, which is a migration per
// feature. The column is jsonb instead, so nothing about its contents is checked
// on the way in — which is why validation is on READ. A row can carry anything a
// past release, a hand-written admin UPDATE, or a future release wrote, and the
// reader decides what it is willing to honour.
//
// Deliberately NOT the bridge's registry (bridge/src/entitlement.ts), which asks
// what a TIER grants from a signed token claim. This one describes a single
// account's contract and never leaves the server. The two vocabularies are
// separate on purpose: how a negotiated capability reaches a bridge is still an
// open question, and answering it by accident — by making these one type — is
// the mistake worth being loud about.

import { z } from "zod";

/**
 * The registry. Every capability is optional: absence and `false` mean the same
 * thing (not granted), so a set that has never been negotiated is `{}` rather
 * than a row of falses that has to be kept in sync as the list grows.
 *
 * Unknown keys are stripped rather than rejected — that is Zod's `z.object`
 * default and it is the behaviour we want. A capability added by a newer release
 * must not make an older reader discard the grants it does understand, and a
 * stripped key grants nothing anyway.
 */
export const CapabilitiesSchema = z.object({
  sso: z.boolean().optional(),
  audit: z.boolean().optional(),
  ipAllowlist: z.boolean().optional(),
});

export type Capabilities = z.infer<typeof CapabilitiesSchema>;
export type CapabilityName = keyof Capabilities;

/** The names, derived from the schema so the two cannot drift. For admin paths
 *  that validate a name a human typed, and for tests. */
export const CAPABILITY_NAMES = Object.keys(CapabilitiesSchema.shape) as CapabilityName[];

/** Grants nothing. The value {@link readCapabilities} falls back to, and the
 *  right initial value for any plan that is not Enterprise. */
export const NO_CAPABILITIES: Capabilities = Object.freeze({});

/**
 * Validate a jsonb column, which is `unknown` until it has been read.
 *
 * Fails CLOSED: anything that does not parse — null, a scalar, an array, a known
 * key holding a non-boolean — yields the empty set. An unreadable capabilities
 * blob is a failure to prove entitlement, not a reason to guess at one, and the
 * only safe guess for a paid feature is "no". Note this is all-or-nothing on
 * purpose: a malformed value anywhere in the object discards the whole object,
 * because a blob we cannot fully account for is not evidence of anything.
 */
export function readCapabilities(value: unknown): Capabilities {
  const parsed = CapabilitiesSchema.safeParse(value);
  return parsed.success ? parsed.data : { ...NO_CAPABILITIES };
}

/** Whether a validated set carries [name]. The only way a call site should ask. */
export function hasCapability(capabilities: Capabilities, name: CapabilityName): boolean {
  return capabilities[name] === true;
}
