// bridge/src/handler/evidence.ts

// Citation primitives for the §2.1 evidence gate. Deliberately dependency-free —
// backlog.ts imports this, and backlog.ts is the module every other handler file
// leans on, so a single import the other way would close a cycle.
//
// What these can and cannot answer: together they decide whether a quote is
// GROUNDED (it really occurs in the material the judge was shown) and whether a
// completion claim NAMES the command the item asked for. Neither can tell a
// correct attribution from a real quote about the wrong subject — that judgement
// needs a reader, and the collapsed Auditor role is exactly the reader we
// refuse to re-introduce.

/** Shortest run of characters that still reads as a citation rather than a
 *  gesture. Below this a quote occurs in almost any corpus by accident, so
 *  grounding would wave it through and the gate would mean nothing. Set low
 *  enough that a terse-but-real citation ("exit code 0") survives; a shorter one
 *  ("exit 0") does not, and that is the cost of having a floor at all. */
export const MIN_EVIDENCE_CHARS = 10;

// Judges rewrite punctuation on the way out — smart quotes from a markdown
// pipeline, an em dash for a hyphen, a non-breaking space in a wrapped line — so
// a raw substring test rejects honest citations for typography alone. Ellipsis
// is folded to the ASCII spelling here so citationSegments only has to know one.
// Written as escapes, never literals: this table is the one place the exact code
// points matter, and a literal NBSP is indistinguishable from a space in every
// editor that will ever open this file.
const SUBSTITUTIONS: [RegExp, string][] = [
  [/[\u2018\u2019\u201b]/g, "'"],
  [/[\u201c\u201d\u201f]/g, '"'],
  [/[\u2013\u2014\u2212]/g, "-"],
  [/[\u00a0\u2007\u202f]/g, " "],
  [/\u2026/g, "..."],
];

export function normalizeForCitation(s: string): string {
  let out = s.toLowerCase();
  for (const [re, to] of SUBSTITUTIONS) out = out.replace(re, to);
  return out.replace(/\s+/g, " ").trim();
}

/** Split a normalized quote at its elisions. A judge that drops the middle of a
 *  line is still citing honestly, so each surviving run is matched separately —
 *  but only runs long enough to discriminate. Two- and three-character fragments
 *  ("in", "the") occur everywhere, so a quote spliced down to those would clear
 *  grounding on a corpus that never contained it. */
export function citationSegments(normalized: string): string[] {
  return normalized.split(/\.{3,}/).map((p) => p.trim()).filter((p) => p.length >= 4);
}

/** Sequential containment: every segment must appear, and in the order the judge
 *  wrote them. An unordered check would let a quote be assembled backwards out of
 *  fragments that never sat together. */
export function containsInOrder(hay: string, segments: string[]): boolean {
  let cursor = 0;
  for (const seg of segments) {
    const at = hay.indexOf(seg, cursor);
    if (at < 0) return false;
    cursor = at + seg.length;
  }
  return true;
}

// The token shape mirrors reply-shape.ts's VERB — one token, no second `/`, no
// backslash — because that is the only thing the harness will ever actually
// INVOKE, so it is the only shape an item can be asking for. The second-slash
// rule is what keeps `/tmp/foo` out: a path fragment is not a command, and
// treating one as an item's named command would demand evidence of a command
// that does not exist. A leading letter is required for the same reason `1/2` is
// not a match — a digit after the slash is arithmetic or a path, never a verb.
const TOKEN_SCAN = /(?:^|[\s"'`(\[])(\/[^\s"'`)\]]+)/g;
const COMMAND_TOKEN = /^\/[a-z][^\s/\\]*$/;

/** Every slash-command-shaped token in a piece of text, lowercased and deduped.
 *  Read off USER-authored item text, never judge output: it is what the item
 *  asked for, and the whole point is that the judge cannot choose it. */
export function commandTokens(text: string): string[] {
  const found = new Set<string>();
  for (const m of text.matchAll(TOKEN_SCAN)) {
    // Sentence punctuation rides along on a token quoted in prose ("run /init.")
    // and is never part of the verb.
    const token = m[1]!.toLowerCase().replace(/[.,;:!?]+$/, "");
    if (COMMAND_TOKEN.test(token)) found.add(token);
  }
  return [...found];
}
