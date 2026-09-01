// bridge/src/handler/destructive-floor.ts

// The act path can cause the agent to run commands with NO human in the loop and
// WITHOUT passing the phone+allowlist gate that guards normal terminal:input.
//
// Advisory by default (spec §5.1): a match yields a WARNING that is recorded and
// fed back to the Assistant, not a veto. A regex that silently overrode a proposal
// the Assistant made blind taught it nothing about which of its own proposals were
// dangerous; a warning is strictly better input. The property that buys back is
// reversibility (§5.2), not prevention — except for the residual HARD tier below,
// which nothing undoes and which therefore still blocks.

export type FloorTier = "HARD" | "DESTRUCTIVE" | "EGRESS" | "SECRETS" | "ABS_PATH";

export interface FloorWarning {
  tier: FloorTier;
  /** Regex source — the stable key an authorization pattern lift is granted against (§5.4). */
  pattern: string;
  /** The text that tripped it, bounded: this reaches a prompt and an activity row. */
  matched: string;
}

// Two lists rather than one list the caller filters: a caller that forgets to
// filter for HARD fails OPEN, and this is the one tier where that is unrecoverable.
export interface FloorResult {
  /** §5.3 — unrecoverable, still escalates. Never liftable by authorization. */
  hard: FloorWarning[];
  /** §5.1 — recorded unsuppressibly and fed to the next decide prompt. */
  warnings: FloorWarning[];
}

// Five unrecoverable shapes (§5.3). No snapshot undoes these and none has a
// legitimate use inside a coding-agent session, so keeping them hard costs no
// false positives. `dd`/`>` are device-scoped here — a dd between two files is
// destructive but recoverable, so it stays advisory below.
const HARD: RegExp[] = [
  /\bmkfs(\.[a-z0-9]+)?\b/i,
  /\bwipefs\b/i,
  /\bdd\s+[^\n]*\b(?:if|of)=\/dev\/(?:sd|nvme|vd|hd|mapper|disk)/i,
  />\s*\/dev\/(?:sd|nvme|vd|hd|mapper|disk)/i,
  /:\s*\(\s*\)\s*\{[^}]*\}\s*;\s*:/, // fork bomb
];

const DESTRUCTIVE: RegExp[] = [
  // Recursive or forced rm in any flag spelling. Denylists leak by design, so match the
  // long forms (--recursive/--force/--no-preserve-root) the short-flag-only patterns missed,
  // plus rm-equivalent deleters (find -delete/-exec rm, shred). A bare `rm file` (no -r/-f)
  // stays unflagged — single in-project file deletes are the common benign auto-reply.
  /\brm\s+(?:-[a-zA-Z]*[rf]|--recursive\b|--force\b|--no-preserve-root\b)/i,
  /\bfind\s+[^\n]*(?:-delete\b|-exec\s+rm\b)/i,
  /\bshred\b/i,
  /\bgit\s+reset\s+--hard/i,
  // [^\n]* spans the args up to the flag; do NOT anchor with \s — the flag (or a leading-`+`
  // force refspec) can sit anywhere on the push line. --mirror/--delete also rewrite remote refs.
  /\bgit\s+push\s+[^\n]*(?:--force(?:-with-lease)?|--mirror\b|--delete\b|-f\b)/i,
  // The optional group is what lets the `+` sit directly after `push` — `git push +main`
  // is as ordinary a force refspec as `git push origin +main`, and requiring whitespace
  // before it unconditionally matched neither.
  /\bgit\s+push\s+(?:[^\n]*\s)?\+\S/i,
  // Both force spellings, and the flag may sit behind -d/-x/a pathspec. Keep in
  // lockstep with planSnapshots' own force detection: a clean this misses is a
  // clean the §5.2 snapshot pass is never asked to protect.
  /\bgit\s+clean\s+[^\n]*(?:--force\b|-[a-zA-Z]*f)/i,
  /\bdd\s+[^\n]*\b(?:if|of)=/i,
  /\b(drop|truncate)\s+(table|database)\b/i,
  /\bchmod\s+-R\b/i,
  /\bchown\s+-R\b/i,
  // Outward moves: a merged pull request, a published version, a deleted ref. No §5.2
  // snapshot reaches any of them — the state that moved lives on a remote or in a
  // registry — so what these buy is the audit row and a lift that has to be asked for,
  // never an undo.
  //
  // Advisory rather than HARD even though nothing undoes them: merging the pull request
  // is routinely the backlog's whole point, and a HARD entry is liftable by nothing, so
  // promoting these would block the very operation the user authorized.
  //
  // The branch pattern alone carries no `i` flag: `-d` and `-D` are different commands.
  // The lowercase one refuses to drop an unmerged branch and so destroys nothing, and
  // case-folding it would flag the safe spelling — the warning nobody should act on.
  /\bgh\s+pr\s+(?:merge|close)\b/i,
  /\bgh\s+(?:release|repo)\s+delete\b/i,
  /\bgit\s+branch\s+(?=[^\n]*(?:-[a-zA-Z]*[dD]\b|--delete\b))[^\n]*(?:-[a-zA-Z]*D\b|--force\b|-[a-zA-Z]*f\b)/,
  /\bgit\s+tag\s+[^\n]*(?:-d\b|--delete\b)/i,
  /\bnpm\s+publish\b/i,
];

// Data exfiltration / reverse shells. Downloads (curl URL / wget URL with no
// upload flag) stay unflagged — only uploads and pipes-into-network tools match.
const EGRESS: RegExp[] = [
  /\|\s*(?:nc|ncat|netcat|curl|wget|telnet|socat)\b/i,
  /\b(?:curl|wget)\s+[^\n]*(?:--data(?:-binary)?\b|-d\b|--form\b|-F\b|--upload-file\b|-T\b)/i,
  /\/dev\/tcp\//i,
  /\bnc(?:at)?\s+[^\n]*-e\b/i,
];

// A warning nobody should act on is noise that trains the Assistant to discount
// warnings generally (§5.1), so the four patterns that matched a *mention* rather
// than an *access* are gated behind a read verb or a redirect. `ls ~/.ssh` and
// "fix auth credentials test" are the corpus cases this exists for.
const READ_ACCESS = String.raw`(?:\b(?:cat|bat|head|tail|less|more|nl|strings|xxd|od|hexdump|base64|openssl|curl|wget|scp|rsync|cp|mv|tar|zip|source)\b|<)`;
const underReadVerb = (target: string) => new RegExp(`${READ_ACCESS}[^\\n]*${target}`, "i");

const SECRETS: RegExp[] = [
  // `.env` but not `.env.example`/`.sample`/`.template`/`.dist`/`.schema` — those are
  // committed placeholders, and flagging them flags half the repos that have one.
  /\.env(?!\.(?:example|sample|template|dist|schema))\b/i,
  underReadVerb(String.raw`\bsecrets?\b`),
  underReadVerb(String.raw`\bcredentials?\b`),
  underReadVerb(String.raw`\.ssh\b`),
  // Shape-based entries are already precise and need no read-verb gate.
  /\bid_(?:rsa|dsa|ecdsa|ed25519)\b/i,
  /private[_\s-]?key/i,
  /\bprintenv\b/i,
  // Reading a secret-shaped env var: $AWS_SECRET_ACCESS_KEY, $GITHUB_TOKEN, etc. The `_`
  // in SECRET_ACCESS defeats a \bsecret\b word boundary, so match the whole var name.
  /\$[A-Za-z_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Za-z_]*/i,
  /\bAKIA[0-9A-Z]{16}\b/,
];

// A path claim needs an INTERIOR separator. A slash command is "/"-shaped too, and
// reading `/code-review` as an out-of-project path teaches the Assistant that its own
// commands are dangerous — in the one channel (§5.1) that exists to teach it which of
// its proposals actually are. reply-shape's VERB rule forbids a "/" inside a verb, so
// an interior separator is precisely the shape a slash command can never have.
//
// The cost is the bare single-segment roots — `/tmp`, `/etc`, `/opt` — which no longer
// register as a mention. Acting on one is still caught: the four tiers above scan the
// full text, and authorization.ts's own outside-target check still reads them, so no
// pattern lift can authorize `rm -rf /tmp`.
//
// The drive-letter branch keeps single-segment coverage (`C:\Temp`), because no slash
// command can be spelled that way and there is nothing to disambiguate.
//
// `\/+` absorbs repeated leading slashes: `//etc/shadow` names the same file as
// `/etc/shadow` on every POSIX kernel, and the leading anchor allows no restart on
// an interior slash — so without it that spelling matched NEITHER branch. It cost
// the warning and, because quickChoicesFor withholds its one-tap chip on any floor
// hit, handed the draft a live Approve chip the single-slash spelling does not get.
// Unlike the bare roots below it, that shape is chosen by whoever wrote the text.
const ABS_PATH = /(?:^|[\s'"=])(\/+[^\s'"/]+\/[^\s'"]*|[A-Za-z]:\\[^\s'"]+)/g;

// One synthetic key for every outside-project path, because this tier is lifted
// literally (§5.4) — the path is the claim, the pattern never is.
export const ABS_PATH_RULE = "absolute path outside project";

const MAX_MATCHED_CHARS = 120;
// A pasted blob can trip the same tier dozens of times. The prompt and the
// activity row both read better truncated than exhaustive, and an Assistant given
// forty warnings learns to skim them.
//
// Budgeted PER TIER, not across all of them: the tiers are scanned in a fixed order
// and that order is not severity, so one shared budget let ten DESTRUCTIVE matches
// starve the SECRETS and ABS_PATH scans that run after them — dropping `cat
// ~/.ssh/id_rsa` from the same reply out of the warnings, the audit trail, and
// anything partitionWarnings could have escalated on.
const MAX_WARNINGS_PER_TIER = 10;

// Separator-aware containment so "/home/me/proj" does NOT swallow
// "/home/me/proj-evil". Normalize Windows backslashes + drive-letter case so a
// forward-slash judge reply still matches a backslashed projectPath on Windows.
export function isInsideProject(p: string, projectPath: string): boolean {
  const norm = (s: string) => s.replace(/\\/g, "/").replace(/^([A-Za-z]):/, (_m, d) => `${d.toLowerCase()}:`);
  const base = norm(projectPath).replace(/\/+$/, "");
  const target = norm(p);
  return target === base || target.startsWith(`${base}/`);
}

function push(out: FloorWarning[], seen: Set<string>, tally: Map<FloorTier, number>, w: FloorWarning): void {
  // Injective without needing a separator byte no field can contain. The NUL that
  // used to do that job was written RAW, which makes git treat the file deciding what
  // "destructive" means as binary — undiffable, unblameable, unmergeable.
  const key = JSON.stringify([w.tier, w.pattern, w.matched]);
  const spent = tally.get(w.tier) ?? 0;
  if (seen.has(key) || spent >= MAX_WARNINGS_PER_TIER) return;
  seen.add(key);
  tally.set(w.tier, spent + 1);
  out.push(w);
}

function scan(
  out: FloorWarning[], seen: Set<string>, tally: Map<FloorTier, number>,
  tier: FloorTier, patterns: RegExp[], text: string,
): void {
  for (const re of patterns) {
    const m = re.exec(text);
    if (m) push(out, seen, tally, { tier, pattern: re.source, matched: m[0].slice(0, MAX_MATCHED_CHARS) });
  }
}

/**
 * Every tier is scanned to completion — unlike the old gate, which returned on the
 * first match. A warning is context now, and the Assistant reading "recursive
 * delete AND outside-project path" makes a better call than one reading whichever
 * happened to be listed first.
 *
 * pathCheckText scopes the outside-project check away from a slash command's VERB and
 * nothing else: engine.ts passes the judge's reply plus the command's argument tail, and
 * withholds the verb alone. What makes that safe is reply-shape's VERB rule, which forbids
 * both separators inside a verb — so no verb the harness will send can carry a path shape,
 * whatever ABS_PATH happens to accept. Catalog membership is NOT the reason: a PTY session
 * has no catalog and its verb is typed at the agent verbatim. Its arguments are ordinary
 * free text and DO get scanned, because an absolute path there is a real one. The other
 * tiers still scan the full `text` (the default for pathCheckText too), so a verb smuggling
 * one of those patterns is caught.
 */
export function classifyDestructive(text: string, projectPath: string, pathCheckText: string = text): FloorResult {
  const hard: FloorWarning[] = [];
  const warnings: FloorWarning[] = [];
  const seen = new Set<string>();
  const tally = new Map<FloorTier, number>();

  scan(hard, seen, tally, "HARD", HARD, text);
  scan(warnings, seen, tally, "DESTRUCTIVE", DESTRUCTIVE, text);
  scan(warnings, seen, tally, "EGRESS", EGRESS, text);
  scan(warnings, seen, tally, "SECRETS", SECRETS, text);

  for (const m of pathCheckText.matchAll(ABS_PATH)) {
    const p = m[1]!;
    if (!isInsideProject(p, projectPath)) {
      push(warnings, seen, tally, { tier: "ABS_PATH", pattern: ABS_PATH_RULE, matched: p.slice(0, MAX_MATCHED_CHARS) });
    }
  }

  return { hard, warnings };
}

/** One-line rendering shared by the activity reason, the escalation, and the decide prompt. */
export function describeWarning(w: FloorWarning): string {
  const label: Record<FloorTier, string> = {
    HARD: "unrecoverable command",
    DESTRUCTIVE: "destructive command",
    EGRESS: "network egress / reverse shell",
    SECRETS: "secret/credential access",
    ABS_PATH: "absolute path outside project",
  };
  return `${label[w.tier]}: ${w.matched}`;
}
