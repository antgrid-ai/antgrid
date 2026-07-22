/**
 * Locate a symbol across every workspace at once — bridge ⇄ relay ⇄ web ⇄ app ⇄
 * packages ⇄ evals — and split definitions from usages in one pass.
 *
 *   bun run scripts/sym.ts <Symbol>           # all matches, defs first
 *   bun run scripts/sym.ts <Symbol> --defs    # only likely definitions
 *   bun run scripts/sym.ts <Symbol> --ts      # restrict to .ts/.tsx
 *   bun run scripts/sym.ts <Symbol> --dart    # restrict to .dart
 *   bun run scripts/sym.ts <Symbol> --all     # include docs/markdown (off by default)
 *   bun run scripts/sym.ts <Symbol> --json
 *
 * By default only code is searched; `.md` and `docs/` are excluded so prose and
 * plan files don't bury real hits. Pass --all to search every tracked file.
 *
 * Replaces the dozens of one-off `rg "Foo\b" path/to/one/file.ts` invocations:
 * cross-package symbols (RelayClient, dispatchInbound, deviceUuid, enableRelay,
 * attachTransport …) live in TS on one side and are mirrored by hand in Dart on
 * the other, so a single whole-repo, word-boundary search beats guessing files.
 *
 * Read-only. Thin wrapper over `git grep` (always on PATH, unlike a separate
 * ripgrep), which only searches tracked files — so node_modules / generated
 * prisma / .dart_tool are skipped for free.
 */
import { spawnSync } from "node:child_process";

const argv = process.argv.slice(2);
const flags = new Set(argv.filter((a) => a.startsWith("--")));
const symbol = argv.find((a) => !a.startsWith("--"));

if (!symbol) {
  console.error("Usage: bun run scripts/sym.ts <Symbol> [--defs] [--ts|--dart|--all] [--json]");
  process.exit(1);
}

const wantJson = flags.has("--json");
const defsOnly = flags.has("--defs");

// `git grep -nw -F`: line numbers, whole-word, fixed-string (so `Foo` doesn't
// hit `FooBar`/`getFoo`, and regex metachars in the symbol need no escaping).
const gitArgs = ["grep", "-n", "-w", "--fixed-strings", "-e", symbol];
const pathspecs: string[] = [];
if (flags.has("--ts")) pathspecs.push("*.ts", "*.tsx");
else if (flags.has("--dart")) pathspecs.push("*.dart");
else if (!flags.has("--all")) {
  // Default: search code, skip prose (markdown + design/plan docs) that otherwise
  // buries real hits. `--all` searches every tracked file. Uses git pathspec magic.
  pathspecs.push(".", ":(exclude)*.md", ":(exclude)docs/");
}
if (pathspecs.length) gitArgs.push("--", ...pathspecs);

const r = spawnSync("git", gitArgs, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
if (r.status === 1) { console.log(`No matches for "${symbol}".`); process.exit(0); }
if (r.status !== 0) { console.error(r.stderr || "git grep failed"); process.exit(r.status ?? 1); }

// Definition heuristics — keyword-anchored so call sites (`new Foo(`,
// `obj.foo(...)`) don't masquerade as defs. Covers TS + the Dart mirror pairs.
const sym = symbol.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const defRe = new RegExp(
  // (a) Type/callable declaration — the symbol IS the declared name:
  `(^|[^\\w.])(export\\s+)?(default\\s+)?(abstract\\s+)?(async\\s+)?` +
  `(function\\*?|class|interface|type|enum|mixin|extension|typedef)\\s+${sym}\\b` +
  // (b) Variable/const binding — symbol is the bound name, so it's followed by
  // `=` / `:` / `;` / EOL. Excludes Dart `final <Symbol> field`, where the symbol
  // is the TYPE (followed by another identifier) not the name being defined:
  `|(^|[^\\w.])(export\\s+)?(const|let|var|final|late)\\s+${sym}\\s*([=:;]|$)` +
  // (c) Dart typed member/method declaration: `void foo(`, `Future<X> foo(`:
  `|(^|[^\\w.])(void|String|int|bool|double|num|Future|Stream|Widget|List|Map)(<[^>]*>)?\\s+${sym}\\s*[(<]`,
);

type Hit = { file: string; line: number; text: string; def: boolean };
const hits: Hit[] = [];
for (const raw of r.stdout.split(/\r?\n/)) {
  if (!raw.trim()) continue;
  // git grep output: path:line:text  (repo-relative paths, forward slashes)
  const m = raw.match(/^(.*?):(\d+):(.*)$/);
  if (!m) continue;
  const [, file, lineStr, text] = m;
  hits.push({ file, line: parseInt(lineStr, 10), text: text.trim(), def: defRe.test(text) });
}

const defs = hits.filter((h) => h.def);
const uses = hits.filter((h) => !h.def);
const shown = defsOnly ? defs : [...defs, ...uses];

if (wantJson) {
  console.log(JSON.stringify({ symbol, defCount: defs.length, useCount: uses.length, hits: shown }, null, 2));
  process.exit(0);
}

function printGroup(title: string, group: Hit[]) {
  if (!group.length) return;
  console.log(`\n${title} (${group.length})`);
  let lastFile = "";
  for (const h of group) {
    if (h.file !== lastFile) { console.log(`  ${h.file}`); lastFile = h.file; }
    console.log(`    ${String(h.line).padStart(5)}  ${h.text}`);
  }
}

console.log(`"${symbol}" — ${defs.length} likely def(s), ${uses.length} usage(s)`);
printGroup("DEFINITIONS", defs);
if (!defsOnly) printGroup("USAGES", uses);
