// bridge/src/handler/destructive-floor.ts

// The act path can cause the agent to run commands with NO human in the loop and
// WITHOUT passing the phone+allowlist gate that guards normal terminal:input. This
// floor is the harness limit (Spec Guardrail #4). Bias is intentionally conservative:
// on any match we force escalation, accepting false positives over a regretted action.

export interface FloorResult { blocked: boolean; reason?: string; }

const DESTRUCTIVE: RegExp[] = [
  // Recursive or forced rm in any flag spelling. Denylists leak by design, so match the
  // long forms (--recursive/--force/--no-preserve-root) the short-flag-only patterns missed,
  // plus rm-equivalent deleters (find -delete/-exec rm, shred). A bare `rm file` (no -r/-f)
  // stays allowed — single in-project file deletes are the common benign auto-reply.
  /\brm\s+(?:-[a-zA-Z]*[rf]|--recursive\b|--force\b|--no-preserve-root\b)/i,
  /\bfind\s+[^\n]*(?:-delete\b|-exec\s+rm\b)/i,
  /\bshred\b/i,
  /\bgit\s+reset\s+--hard/i,
  // [^\n]* spans the args up to the flag; do NOT anchor with \s — the flag (or a leading-`+`
  // force refspec) can sit anywhere on the push line. --mirror/--delete also rewrite remote refs.
  /\bgit\s+push\s+[^\n]*(?:--force(?:-with-lease)?|--mirror\b|--delete\b|-f\b)/i,
  /\bgit\s+push\s+[^\n]*\s\+\S/i,
  /\bgit\s+clean\s+-[a-z]*f/i,
  /\bdd\s+[^\n]*\b(?:if|of)=/i,
  /\bmkfs(\.[a-z0-9]+)?\b/i,
  /\bwipefs\b/i,
  /\b(drop|truncate)\s+(table|database)\b/i,
  /\bchmod\s+-R\b/i,
  /\bchown\s+-R\b/i,
  />\s*\/dev\/(?:sd|nvme|vd|hd|mapper|disk)/i,
  /:\s*\(\s*\)\s*\{[^}]*\}\s*;\s*:/, // fork bomb
];

// Data exfiltration / reverse shells: the act path can run commands the phone never
// approved, so block egress shapes outright. Downloads (curl URL / wget URL with no
// upload flag) stay allowed — only uploads and pipes-into-network tools are blocked.
const EGRESS: RegExp[] = [
  /\|\s*(?:nc|ncat|netcat|curl|wget|telnet|socat)\b/i,
  /\b(?:curl|wget)\s+[^\n]*(?:--data(?:-binary)?\b|-d\b|--form\b|-F\b|--upload-file\b|-T\b)/i,
  /\/dev\/tcp\//i,
  /\bnc(?:at)?\s+[^\n]*-e\b/i,
];

const SECRETS: RegExp[] = [
  /\.env\b/i,
  /\bsecrets?\b/i,
  /\bcredentials?\b/i,
  /\bid_(?:rsa|dsa|ecdsa|ed25519)\b/i,
  /private[_\s-]?key/i,
  /\.ssh\b/i,
  /\bprintenv\b/i,
  // Reading a secret-shaped env var: $AWS_SECRET_ACCESS_KEY, $GITHUB_TOKEN, etc. The `_`
  // in SECRET_ACCESS defeats a \bsecret\b word boundary, so match the whole var name.
  /\$[A-Za-z_]*(?:SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|ACCESS_KEY|PRIVATE_KEY)[A-Za-z_]*/i,
  /\bAKIA[0-9A-Z]{16}\b/,
];

const ABS_PATH = /(?:^|[\s'"=])(\/[^\s'"]+|[A-Za-z]:\\[^\s'"]+)/g;

// Separator-aware containment so "/home/me/proj" does NOT swallow
// "/home/me/proj-evil". Normalize Windows backslashes + drive-letter case so a
// forward-slash judge reply still matches a backslashed projectPath on Windows.
function isInsideProject(p: string, projectPath: string): boolean {
  const norm = (s: string) => s.replace(/\\/g, "/").replace(/^([A-Za-z]):/, (_m, d) => `${d.toLowerCase()}:`);
  const base = norm(projectPath).replace(/\/+$/, "");
  const target = norm(p);
  return target === base || target.startsWith(`${base}/`);
}

export function classifyDestructive(text: string, projectPath: string): FloorResult {
  for (const re of DESTRUCTIVE) if (re.test(text)) return { blocked: true, reason: `destructive command pattern (${re.source})` };
  for (const re of EGRESS) if (re.test(text)) return { blocked: true, reason: `network egress / reverse shell (${re.source})` };
  for (const re of SECRETS) if (re.test(text)) return { blocked: true, reason: `secret/credential reference (${re.source})` };
  for (const m of text.matchAll(ABS_PATH)) {
    const p = m[1];
    if (!isInsideProject(p, projectPath)) return { blocked: true, reason: `absolute path outside project: ${p}` };
  }
  return { blocked: false };
}
