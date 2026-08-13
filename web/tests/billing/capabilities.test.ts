import { describe, test, expect } from "bun:test";
import {
  CAPABILITY_NAMES,
  NO_CAPABILITIES,
  hasCapability,
  readCapabilities,
} from "../../src/billing/capabilities.js";

/**
 * The column is jsonb, so nothing checks its contents on the way in — a row can
 * hold whatever a past release, a hand-written admin UPDATE or a newer release
 * wrote. These are the shapes that actually reach `readCapabilities`, and the
 * fail-closed rule is only worth anything if the malformed ones land on the
 * empty set rather than on a partially-honoured grant.
 */
describe("readCapabilities", () => {
  test("keeps the grants a well-formed object carries", () => {
    expect(readCapabilities({ sso: true, audit: false })).toEqual({
      sso: true,
      audit: false,
    });
  });

  test("the empty object is a valid set that grants nothing", () => {
    expect(readCapabilities({})).toEqual({});
  });

  test("strips a name this build does not know while keeping the ones it does", () => {
    // A capability added by a newer release must not cost an older reader the
    // grants it does understand, and a stripped key grants nothing anyway.
    expect(readCapabilities({ sso: true, quantumSso: true })).toEqual({ sso: true });
  });

  test("a known name holding a non-boolean discards the whole set", () => {
    // All-or-nothing on purpose: a blob that cannot be fully accounted for is
    // not evidence of the grants that happen to parse.
    expect(readCapabilities({ sso: "yes", audit: true })).toEqual({});
  });

  test("null grants nothing", () => {
    expect(readCapabilities(null)).toEqual({});
  });

  test("a non-object grants nothing", () => {
    expect(readCapabilities("sso")).toEqual({});
    expect(readCapabilities(42)).toEqual({});
    expect(readCapabilities([{ sso: true }])).toEqual({});
    expect(readCapabilities(undefined)).toEqual({});
  });

  test("the fallback is a fresh object, so a caller cannot poison the next read", () => {
    const fallback = readCapabilities(null) as Record<string, boolean>;
    fallback.sso = true;

    expect(readCapabilities(null)).toEqual({});
    expect(NO_CAPABILITIES).toEqual({});
  });
});

describe("hasCapability", () => {
  test("true only for a name the set explicitly grants", () => {
    const caps = readCapabilities({ sso: true, audit: false });

    expect(hasCapability(caps, "sso")).toBe(true);
    expect(hasCapability(caps, "audit")).toBe(false);
    expect(hasCapability(caps, "ipAllowlist")).toBe(false);
  });

  test("nothing survives a blob that failed to parse", () => {
    const caps = readCapabilities({ sso: "yes" });

    for (const name of CAPABILITY_NAMES) {
      expect({ name, granted: hasCapability(caps, name) }).toEqual({ name, granted: false });
    }
  });
});

describe("the registry", () => {
  test("names are derived from the schema, so the two cannot drift", () => {
    expect(CAPABILITY_NAMES).toEqual(["sso", "audit", "ipAllowlist"]);
  });
});
