// bridge/tests/handler/evidence.test.ts
import { describe, it, expect } from "bun:test";
import {
  MIN_EVIDENCE_CHARS,
  citationSegments,
  commandTokens,
  containsInOrder,
  normalizeForCitation,
} from "../../src/handler/evidence";

describe("normalizeForCitation", () => {
  // An honest judge quoting out of a markdown pipeline delivers the same sentence
  // in different code points. Rejecting that spends the whole gate on typography
  // and teaches nothing about whether the work happened.
  it("makes a rewritten quote equal to its plain-ASCII source", () => {
    const source = 'the "auth" module - rewritten and covered';
    const quoted = "the \u201cauth\u201d module \u2014 rewritten\u00a0and   covered";
    expect(normalizeForCitation(quoted)).toBe(normalizeForCitation(source));
  });

  it("folds the ellipsis character to the ASCII spelling so only one is ever matched", () => {
    expect(normalizeForCitation("first\u2026last")).toBe(normalizeForCitation("first...last"));
  });

  it("is case-insensitive and trims", () => {
    expect(normalizeForCitation("  PASS 14 Tests  ")).toBe("pass 14 tests");
  });
});

describe("citationSegments", () => {
  it("keeps a quote with no elision as one segment", () => {
    expect(citationSegments("14 tests passed in 0.4s")).toEqual(["14 tests passed in 0.4s"]);
  });

  it("splits at an elision and trims each side", () => {
    expect(citationSegments("the suite ... passed cleanly"))
      .toEqual(["the suite", "passed cleanly"]);
  });

  // Two- and three-character runs occur in every corpus, so a quote spliced down
  // to those would ground against material that never contained it.
  it("drops fragments too short to discriminate", () => {
    expect(citationSegments("in ... the ... of")).toEqual([]);
  });
});

describe("containsInOrder", () => {
  const HAY = "the auth module was rewritten and covered by tests";

  it("accepts an elided quote whose halves appear in order", () => {
    expect(containsInOrder(HAY, ["the auth module", "covered by tests"])).toBe(true);
  });

  // Without the advancing cursor a quote could be assembled backwards out of
  // fragments that never sat together in the record.
  it("rejects the same halves in reverse order", () => {
    expect(containsInOrder(HAY, ["covered by tests", "the auth module"])).toBe(false);
  });

  it("rejects a segment that is absent altogether", () => {
    expect(containsInOrder(HAY, ["the auth module", "shipped to prod"])).toBe(false);
  });

  // No segments means nothing was checked, which is a caller's problem to catch —
  // the length floor above this is what refuses it.
  it("accepts an empty segment list", () => {
    expect(containsInOrder(HAY, [])).toBe(true);
  });
});

describe("commandTokens", () => {
  it("finds a slash command in prose and strips sentence punctuation", () => {
    expect(commandTokens("run /code-review --fix")).toEqual(["/code-review"]);
    expect(commandTokens("then run /init.")).toEqual(["/init"]);
  });

  it("is case-insensitive and deduplicates", () => {
    expect(commandTokens("run /Compact then /compact again")).toEqual(["/compact"]);
  });

  // A path is not a verb: the harness can only ever invoke the shape reply-shape's
  // VERB accepts, so anything with a second separator is not what the item asked
  // for and must not impose an anchor no evidence could satisfy.
  it("ignores a multi-segment path and a bare fraction", () => {
    expect(commandTokens("copy it to /tmp/foo")).toEqual([]);
    expect(commandTokens("open /tmp\\foo")).toEqual([]);
    expect(commandTokens("1/2 of the suite")).toEqual([]);
  });

  it("requires a boundary before the slash", () => {
    expect(commandTokens("https://example.com/init")).toEqual([]);
  });

  it("finds a token quoted or bracketed", () => {
    expect(commandTokens('the "/compact" step')).toEqual(["/compact"]);
    expect(commandTokens("(/compact)")).toEqual(["/compact"]);
  });

  // The documented cost of mirroring VERB rather than a command catalog: a
  // single-segment path is verb-shaped, and `.claude/commands/*.md` lets a user
  // name a command anything, so the two cannot be told apart by shape.
  it("reads a single-segment absolute path as a command", () => {
    expect(commandTokens("cd /usr and run make")).toEqual(["/usr"]);
  });

  it("finds nothing in an item that names no command", () => {
    expect(commandTokens("review the code and fix what you find")).toEqual([]);
  });
});

describe("MIN_EVIDENCE_CHARS", () => {
  // A judgement call with no data behind it, pinned so a change to it is a
  // deliberate edit rather than a drift: "exit code 0" survives, "exit 0" does not.
  it("is set where a terse but real citation still clears it", () => {
    expect("exit code 0".length).toBeGreaterThanOrEqual(MIN_EVIDENCE_CHARS);
    expect("exit 0".length).toBeLessThan(MIN_EVIDENCE_CHARS);
  });
});
