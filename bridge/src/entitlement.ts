// bridge/src/entitlement.ts

// Entitlement: does the account behind this machine's device token pay for a
// given capability. The answer comes off the server-signed `tier` claim already
// minted into every device access token (web/src/auth/oauth-provider.ts) — no
// new claim, no numeric cap, and nothing the client computes for itself.
//
// Deliberately named for entitlement and deliberately NOT in `handler/`.
// `handler/authorization.ts` is instruction-scoped tool lifting — what a
// sentence a human typed permits a supervised agent to do — and it is
// attacker-adjacent security code. This file decides what a subscription bought.
// Two things called authorization in one directory would eventually be read,
// and edited, as one thing.
//
// This registry is the ONE place a capability is added: name it in
// {@link CAPABILITIES}, give it a grant set in `CAPABILITY_TIERS`, and every
// consumer asks the same predicate. A `tier === "pro"` written at a call site is
// exactly the drift this exists to prevent, and bridge/tests/entitlement.test.ts
// fails on one.

/**
 * Product lines web can mint. Hand-mirrors `DEVICE_TIERS` in
 * relay/src/license/verify.ts and the `tier` column of web's plan catalog —
 * three workspaces, no shared type (the Apache/ELv2 boundary forbids hoisting
 * one into a package). An unrecognised label is treated as unreadable rather
 * than as a tier that happens to grant nothing, so widening the vocabulary is a
 * deliberate edit here rather than a silent grant.
 */
export const KNOWN_TIERS = ["free", "trial", "pro", "enterprise"] as const;
export type Tier = (typeof KNOWN_TIERS)[number];

/** Capabilities the bridge gates on entitlement. The queued ones
 *  (devcontainer, …) join this list and the table below, and nothing else. */
export const CAPABILITIES = ["handler"] as const;
export type Capability = (typeof CAPABILITIES)[number];

const CAPABILITY_TIERS: Record<Capability, ReadonlySet<Tier>> = {
  // Trial is a Pro preview in web's plan catalog (same worker limit, one seat),
  // so it carries Pro's capabilities. Free does not — Handler is the paid lever.
  handler: new Set<Tier>(["trial", "pro", "enterprise"]),
};

/**
 * A live reading of this runtime's device credential. Both fields move
 * together, which is why they are one thunk: a machine can gain credentials
 * after its cores are already warm (the desktop wizard promotes a host launched
 * local-only), so neither half may be captured at construction.
 */
export interface TierClaim {
  /** Whether this runtime holds device credentials AT ALL. False for a bare
   *  agent, a signed-out desktop and every test — flows that never had a token,
   *  and so have nothing to fail closed on. */
  credentialed: boolean;
  /** The tier the CURRENT access token carries, or null when there is no
   *  readable, unexpired claim to read. */
  tier: string | null;
}

export type TierClaimSource = () => TierClaim;

/**
 * The two ways a capability is withheld — and the half of the verdict that is
 * spoken to the user, so it crosses the wire (`handler:status.entitlement` in
 * protocol.ts) and is mirrored by hand app-side. Widening it is a copy edit on
 * three surfaces, which is the point: every reason here owes the reader a
 * sentence saying what to do about it.
 */
export type EntitlementRefusal = "not_entitled" | "unreadable";

/**
 * Why a capability was allowed or refused. `allowed` is the only thing a call
 * site branches on; `reason` exists so a log line can tell the two allowed
 * cases and the two refused cases apart. The split is load-bearing in one
 * direction especially: "nobody wired this" (`unwired`) and "the server said
 * no" (`not_entitled`) land on OPPOSITE sides of `allowed`, so they cannot be
 * confused the way an absent value and a negative one otherwise would be.
 *
 * A union rather than one flat shape so `allowed: false` NARROWS `reason` to
 * the refusals: what the bridge tells the app is derived from a verdict, and a
 * flat type would let `unwired` — the allowed case — be reported as one.
 */
export type EntitlementVerdict =
  | {
      readonly allowed: true;
      readonly reason: "entitled" | "unwired";
      /** The tier the claim carried, when it carried a recognised one. */
      readonly tier?: Tier;
    }
  | {
      readonly allowed: false;
      readonly reason: EntitlementRefusal;
      readonly tier?: Tier;
    };

export type EntitlementReader = (capability: Capability) => EntitlementVerdict;

/**
 * The bridge-side predicate. `source` is a thunk over the LIVE credential,
 * never a captured tier string: a token is re-minted at 80% of its 3600s TTL,
 * and a value frozen at construction would be stale within the hour — which is
 * the exact window the whole design exists to bound.
 *
 * The two refusal cases are both fail-closed, and the allowed cases are both
 * deliberate:
 *   - no source, or `credentialed: false` → ALLOWED (`unwired`). A developer
 *     working locally with no device record never had a token and never will;
 *     refusing here would brick offline and signed-out work that no plan ever
 *     asked to charge for.
 *   - `credentialed: true`, claim missing/expired/unknown → REFUSED
 *     (`unreadable`). This machine HAS credentials, so a claim it cannot read
 *     is a failure to prove entitlement, not the absence of a paywall.
 *   - `credentialed: true`, tier outside the grant set → REFUSED
 *     (`not_entitled`). The paywall itself.
 */
export function createEntitlementReader(source?: TierClaimSource): EntitlementReader {
  return (capability: Capability): EntitlementVerdict => {
    const claim = source?.();
    if (!claim || !claim.credentialed) return { allowed: true, reason: "unwired" };
    const tier = claim.tier;
    if (tier === null || !isKnownTier(tier)) return { allowed: false, reason: "unreadable" };
    return CAPABILITY_TIERS[capability].has(tier)
      ? { allowed: true, reason: "entitled", tier }
      : { allowed: false, reason: "not_entitled", tier };
  };
}

function isKnownTier(value: string): value is Tier {
  return (KNOWN_TIERS as readonly string[]).includes(value);
}

/** The tiers that carry [capability]. Exposed for tests and diagnostics only —
 *  a consumer asks {@link createEntitlementReader}, never this. */
export function tiersGranting(capability: Capability): ReadonlySet<Tier> {
  return CAPABILITY_TIERS[capability];
}
