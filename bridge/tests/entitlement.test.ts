// bridge/tests/entitlement.test.ts
import { describe, expect, it, test } from "bun:test";
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join } from "node:path";
import {
  CAPABILITIES,
  KNOWN_TIERS,
  createEntitlementReader,
  tiersGranting,
  type Capability,
  type Tier,
  type TierClaim,
} from "../src/entitlement";
import { decodeAccessTokenClaims, liveTier } from "../src/auth/access-token-claims";

const SRC = join(import.meta.dir, "..", "src");

function credentialed(tier: string | null): () => TierClaim {
  return () => ({ credentialed: true, tier });
}

describe("the capability registry", () => {
  // Adding a capability means naming it in CAPABILITIES and giving it a grant
  // set. Doing one without the other is the mistake this catches.
  it("gives every declared capability a grant set drawn from the known tiers", () => {
    for (const c of CAPABILITIES) {
      const granting = tiersGranting(c);
      expect(granting.size).toBeGreaterThan(0);
      for (const t of granting) expect(KNOWN_TIERS).toContain(t);
    }
  });

  // The predicate must behave identically for every capability — a second one
  // that needs its own branch is a second gate, which is the shape the plan
  // rules out ("one signed claim, one bridge-side predicate").
  it("answers uniformly for every capability, with no per-capability branch", () => {
    for (const c of CAPABILITIES) {
      const granted = [...tiersGranting(c)][0]!;
      const denied = KNOWN_TIERS.find((t) => !tiersGranting(c).has(t));
      expect(denied).toBeDefined();

      expect(createEntitlementReader(credentialed(granted))(c)).toEqual({
        allowed: true, reason: "entitled", tier: granted,
      });
      expect(createEntitlementReader(credentialed(denied!))(c)).toEqual({
        allowed: false, reason: "not_entitled", tier: denied!,
      });
      expect(createEntitlementReader(credentialed(null))(c)).toEqual({
        allowed: false, reason: "unreadable",
      });
      expect(createEntitlementReader()(c)).toEqual({ allowed: true, reason: "unwired" });
    }
  });

  it("gates Handler on the paid tiers and refuses free", () => {
    const handler: Capability = "handler";
    for (const t of ["pro", "trial", "enterprise"] satisfies Tier[]) {
      expect(createEntitlementReader(credentialed(t))(handler).allowed).toBe(true);
    }
    expect(createEntitlementReader(credentialed("free"))(handler)).toEqual({
      allowed: false, reason: "not_entitled", tier: "free",
    });
  });

  it("treats a tier label it does not recognise as unreadable, never as a grant", () => {
    // Widening the vocabulary has to be a deliberate edit to KNOWN_TIERS. A
    // label web starts minting before the bridge learns it must not slip
    // through as "some tier, therefore fine".
    const r = createEntitlementReader(credentialed("platinum"));
    expect(r("handler")).toEqual({ allowed: false, reason: "unreadable" });
  });

  it("reads the claim live on every call rather than capturing it", () => {
    // The token is re-minted at 80% of a 3600s TTL, so a captured tier is stale
    // within the hour — the exact window the design exists to bound.
    let tier = "pro";
    const r = createEntitlementReader(() => ({ credentialed: true, tier }));
    expect(r("handler").allowed).toBe(true);
    tier = "free";
    expect(r("handler").allowed).toBe(false);
  });
});

describe("the local/offline developer flow", () => {
  // Guarding the carve-out explicitly, because the obvious "fix" to a
  // fail-closed gate is to close it here too — and that brakes every signed-out
  // desktop, every bare agent and every test.
  it("allows a paid capability when no credential source is wired at all", () => {
    expect(createEntitlementReader()("handler")).toEqual({ allowed: true, reason: "unwired" });
  });

  it("allows a paid capability when the runtime holds no device credentials", () => {
    const r = createEntitlementReader(() => ({ credentialed: false, tier: null }));
    expect(r("handler")).toEqual({ allowed: true, reason: "unwired" });
  });

  // The line between the two: having credentials is what makes an unreadable
  // claim a refusal rather than an exemption.
  it("refuses once the machine IS credentialed but the claim will not read", () => {
    expect(createEntitlementReader(credentialed(null))("handler").allowed).toBe(false);
  });
});

describe("the tier claim on a real token", () => {
  function jwt(payload: object): string {
    const seg = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
    return `${seg({ alg: "EdDSA", typ: "JWT" })}.${seg(payload)}.sig`;
  }
  const inAnHour = Math.floor(Date.now() / 1000) + 3600;

  it("reads tier off the payload and gates on it", () => {
    const tier = liveTier(decodeAccessTokenClaims(jwt({ tier: "pro", exp: inAnHour })));
    expect(createEntitlementReader(credentialed(tier))("handler").allowed).toBe(true);
  });

  it("fails closed on an expired token, which is what bounds the downgrade lag", () => {
    const expired = jwt({ tier: "pro", exp: Math.floor(Date.now() / 1000) - 3600 });
    const tier = liveTier(decodeAccessTokenClaims(expired));
    expect(tier).toBeNull();
    expect(createEntitlementReader(credentialed(tier))("handler")).toEqual({
      allowed: false, reason: "unreadable",
    });
  });

  it("fails closed on a token with no tier, no exp, or no JWT shape", () => {
    for (const token of [jwt({ exp: inAnHour }), jwt({ tier: "pro" }), "not-a-jwt", ""]) {
      const tier = liveTier(decodeAccessTokenClaims(token));
      expect(tier).toBeNull();
      expect(createEntitlementReader(credentialed(tier))("handler").allowed).toBe(false);
    }
  });
});

// The registry earns its keep only if it stays the sole place a tier is
// compared. This is the test that fails when someone adds the next capability
// by writing `if (tier === "pro")` next to the feature instead.
test("no module outside entitlement.ts compares against a tier label", () => {
  const compare = /(?:===|!==|==|!=)\s*["'`](?:free|trial|pro|enterprise)["'`]|["'`](?:free|trial|pro|enterprise)["'`]\s*(?:===|!==|==|!=)/;
  const offenders: string[] = [];
  const walk = (dir: string): void => {
    for (const name of readdirSync(dir)) {
      const p = join(dir, name);
      if (statSync(p).isDirectory()) { walk(p); continue; }
      if (!p.endsWith(".ts")) continue;
      if (p === join(SRC, "entitlement.ts")) continue;
      if (compare.test(readFileSync(p, "utf8"))) offenders.push(p.slice(SRC.length + 1));
    }
  };
  walk(SRC);
  expect(offenders).toEqual([]);
});

// A named landmine in the plan: web mints the label, the relay validates it
// against a closed union, and the bridge now branches on it — three workspaces,
// no shared type (the Apache/ELv2 boundary forbids hoisting one into a package).
test("KNOWN_TIERS stays in lockstep with the relay's DEVICE_TIERS", () => {
  const verify = join(import.meta.dir, "..", "..", "relay", "src", "license", "verify.ts");
  expect(existsSync(verify)).toBe(true);
  const m = /const DEVICE_TIERS = \[([^\]]*)\]/.exec(readFileSync(verify, "utf8"));
  expect(m).not.toBeNull();
  const relayTiers = [...m![1]!.matchAll(/"([^"]+)"/g)].map((x) => x[1]!);
  expect([...KNOWN_TIERS].sort() as string[]).toEqual(relayTiers.sort());
});
