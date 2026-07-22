/**
 * Answer "where am I, and is this worktree ready?" in one shot.
 *
 *   bun run scripts/wt-where.ts          # human-readable report
 *   bun run scripts/wt-where.ts --json   # machine-readable (for agents/tooling)
 *
 * Replaces the recurring hand-rolled probes:
 *   git rev-parse --git-common-dir / --show-toplevel, merge-base against main,
 *   ls web/.env relay/.env node_modules/.bin src/generated/prisma app/.dart_tool …
 *
 * Read-only: never mutates anything. Mirrors the main-root detection and the
 * provisioning-artifact list used by scripts/worktree.ts, so the two stay in
 * lockstep — if worktree.ts provisions it, this reports on it.
 */
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { spawnSync } from "node:child_process";

function git(args: string[]): { ok: boolean; out: string } {
  const r = spawnSync("git", args, { encoding: "utf8" });
  return { ok: r.status === 0, out: (r.stdout ?? "").trim() };
}

function norm(p: string): string {
  const r = resolve(p);
  return process.platform === "win32" ? r.toLowerCase() : r;
}

// Artifacts scripts/worktree.ts provisions — a worktree isn't test-ready without them.
const ARTIFACTS: { rel: string; label: string }[] = [
  { rel: "node_modules", label: "TS deps (bun install)" },
  { rel: "web/.env", label: "web env (shared DB/secret)" },
  { rel: "relay/.env", label: "relay env" },
  { rel: "web/src/generated/prisma", label: "prisma client" },
  { rel: "app/.dart_tool/package_config.json", label: "flutter deps (pub get)" },
];

function main() {
  const json = process.argv.includes("--json");

  const top = git(["rev-parse", "--show-toplevel"]);
  if (!top.ok) {
    const msg = "Not inside a git repository.";
    if (json) console.log(JSON.stringify({ error: msg }));
    else console.error(msg);
    process.exit(1);
  }
  const currentRoot = resolve(top.out);
  const mainRoot = resolve(dirname(git(["rev-parse", "--path-format=absolute", "--git-common-dir"]).out));
  const isWorktree = norm(currentRoot) !== norm(mainRoot);
  const branch = git(["rev-parse", "--abbrev-ref", "HEAD"]).out;

  // Divergence from main's tip (only meaningful in a worktree on a feature branch).
  let ahead = 0, behind = 0, base = "";
  if (isWorktree) {
    const mb = git(["merge-base", "HEAD", "main"]);
    if (mb.ok) {
      base = mb.out.slice(0, 8);
      const counts = git(["rev-list", "--left-right", "--count", "main...HEAD"]);
      if (counts.ok) {
        const [b, a] = counts.out.split(/\s+/).map((n) => parseInt(n, 10) || 0);
        behind = b; ahead = a;
      }
    }
  }

  const artifacts = ARTIFACTS.map((x) => ({
    ...x,
    present: existsSync(resolve(currentRoot, x.rel)),
  }));
  const ready = artifacts.every((a) => a.present);

  if (json) {
    console.log(JSON.stringify({
      isWorktree, currentRoot, mainRoot, branch, base, ahead, behind, ready,
      artifacts: artifacts.map(({ rel, present }) => ({ rel, present })),
    }, null, 2));
    return;
  }

  console.log(`location : ${isWorktree ? "WORKTREE" : "main checkout"}`);
  console.log(`cwd-root : ${currentRoot}`);
  if (isWorktree) console.log(`main     : ${mainRoot}`);
  console.log(`branch   : ${branch}`);
  if (isWorktree && base) console.log(`vs main  : base ${base}  (+${ahead} ahead / -${behind} behind)`);
  console.log(`provision: ${ready ? "READY ✓" : "INCOMPLETE ✗"}`);
  for (const a of artifacts) {
    console.log(`  ${a.present ? "✓" : "✗"} ${a.rel}${a.present ? "" : `  — ${a.label}`}`);
  }
  if (!ready) {
    console.log(`\nProvision with:  npm run worktree${isWorktree ? "" : " -- <name>"}`);
  }
}

main();
