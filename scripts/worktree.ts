/**
 * Create a git worktree and set it up ready to run tests — or set up the
 * worktree you're already inside.
 *
 *   bun run scripts/worktree.ts <name> [options]   # create + set up a new worktree
 *   bun run scripts/worktree.ts [options]          # set up the CURRENT worktree
 *
 * Worktrees share .git history and tracked files, but NOT the untracked
 * artifacts the test suites need (node_modules, prisma client, .env files,
 * Flutter .dart_tool). This script provisions all of them so the worktree is
 * test-ready the moment it finishes.
 *
 * Setup steps (in order):
 *   1. [create mode only] git worktree add .claude/worktrees/<name> -b <branch>
 *   2. Copy web/.env + relay/.env from the MAIN checkout (shared DB + secret)
 *   3. bun install at the worktree root  (also runs `prisma generate` via web postinstall)
 *   4. bun run --filter antgrid-web migrate  (idempotent; shared local Postgres)
 *   5. cd app && flutter pub get
 *
 * Mode is chosen by whether <name> is given:
 *   - <name> present  → create a new worktree, then set it up.
 *   - <name> omitted  → set up the worktree the command is run from. Refuses to
 *                       run against the main checkout (there's nothing to set up).
 *
 * Options:
 *   --branch <b>   Branch name to create/attach (default: <name>)  [create mode]
 *   --from <ref>   Base ref for the new branch (default: current HEAD)  [create mode]
 *   --no-flutter   Skip `flutter pub get` (backend-only work)
 *   --no-db        Skip the prisma migrate step
 *   --seed         Run scripts/dev-setup.ts in the worktree (dev user + Pro sub)
 *
 * Idempotent-ish: re-running against an existing worktree skips the add step
 * and re-provisions, so you can repair a half-set-up worktree.
 */
import { existsSync, copyFileSync, mkdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { spawnSync } from "node:child_process";

type Opts = {
  name?: string;
  branch?: string;
  from?: string;
  flutter: boolean;
  db: boolean;
  seed: boolean;
};

function parseArgs(argv: string[]): Opts {
  const positional: string[] = [];
  let branch: string | undefined;
  let from: string | undefined;
  let flutter = true;
  let db = true;
  let seed = false;

  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case "--branch": branch = argv[++i]; break;
      case "--from": from = argv[++i]; break;
      case "--no-flutter": flutter = false; break;
      case "--no-db": db = false; break;
      case "--seed": seed = true; break;
      case "-h": case "--help": usage(0); break;
      default:
        if (a.startsWith("--")) { console.error(`Unknown flag: ${a}`); usage(1); }
        positional.push(a);
    }
  }

  const name = positional[0];
  if (name && !/^[A-Za-z0-9._\-/]+$/.test(name)) {
    console.error(`Invalid name "${name}" — use letters, digits, . _ - / only.`);
    process.exit(1);
  }
  // Reject `..` segments — `join(worktreeParent, name)` would normalize them and
  // place the worktree outside the .claude/worktrees sandbox.
  if (name && name.split(/[/\\]/).includes("..")) {
    console.error(`Invalid name "${name}" — must not contain ".." path segments.`);
    process.exit(1);
  }
  // --seed runs dev-setup.ts, which unconditionally migrates Postgres; honoring
  // --no-db would be a contradiction, so reject the combination up front rather
  // than silently hitting the DB anyway.
  if (seed && !db) {
    console.error("--seed requires database access and cannot be combined with --no-db.");
    process.exit(1);
  }
  return { name, branch: branch ?? name, from, flutter, db, seed };
}

function usage(code: number): never {
  console.log(
    [
      "Usage:",
      "  bun run scripts/worktree.ts <name> [options]   # create + set up a new worktree",
      "  bun run scripts/worktree.ts [options]          # set up the CURRENT worktree",
      "",
      "  --branch <b>   Branch to create/attach (default: <name>)   [create mode]",
      "  --from <ref>   Base ref for the new branch (default: HEAD)  [create mode]",
      "  --no-flutter   Skip `flutter pub get`",
      "  --no-db        Skip prisma migrate",
      "  --seed         Run scripts/dev-setup.ts (dev user + Pro sub)",
    ].join("\n"),
  );
  process.exit(code);
}

/** Capture trimmed stdout of a git command, or exit on failure. */
function git(args: string[]): string {
  const r = spawnSync("git", args, { encoding: "utf8" });
  if (r.status !== 0) {
    console.error(`git ${args.join(" ")} failed:\n${r.stderr ?? ""}`);
    process.exit(1);
  }
  return r.stdout.trim();
}

/** Normalize a path for cross-platform equality (Windows drive-letter case). */
function norm(p: string): string {
  const r = resolve(p);
  return process.platform === "win32" ? r.toLowerCase() : r;
}

/**
 * Quote an arg for shell:true on Windows. With shell enabled, Node concatenates
 * args into one cmd.exe string WITHOUT quoting, so any arg containing a space
 * (e.g. a worktree path under `C:\Users\John Doe\...`) would be split. Wrap such
 * args in double quotes; pass through clean args untouched.
 */
function shellQuote(a: string): string {
  return /[\s"^&|<>()]/.test(a) ? `"${a.replace(/"/g, '\\"')}"` : a;
}

/** Run a command, inheriting stdio. Exits the process on non-zero status. */
function run(cmd: string, args: string[], cwd: string, label: string): void {
  console.log(`\n→ ${label}\n  $ ${cmd} ${args.join(" ")}  (in ${cwd})`);
  const win = process.platform === "win32";
  const finalArgs = win ? args.map(shellQuote) : args;
  const r = spawnSync(cmd, finalArgs, { cwd, stdio: "inherit", shell: win });
  if (r.status !== 0) {
    console.error(`\n✖ ${label} failed (exit ${r.status ?? "signal"}).`);
    process.exit(r.status ?? 1);
  }
}

/** Does a local branch already exist? */
function branchExists(branch: string): boolean {
  const r = spawnSync("git", ["rev-parse", "--verify", "--quiet", `refs/heads/${branch}`], {
    stdio: "ignore",
  });
  return r.status === 0;
}

function copyEnv(rel: string, mainRoot: string, dest: string): void {
  const src = resolve(mainRoot, rel);
  const dst = resolve(dest, rel);
  if (norm(src) === norm(dst)) return; // setting up the main checkout itself — nothing to copy
  if (!existsSync(src)) {
    console.warn(`  ! ${rel} not found in main checkout — skipping copy.` +
      ` Run \`npm run setup\` in main first, or pass --seed.`);
    return;
  }
  mkdirSync(dirname(dst), { recursive: true });
  copyFileSync(src, dst);
  console.log(`  copied ${rel}`);
}

/** Provision an existing worktree dir (steps 2-5 + optional seed). */
function provision(worktreePath: string, mainRoot: string, opts: Opts): void {
  // --- 2. Env files (copy from main; keeps shared DB + secret consistent) ---
  console.log(`\n→ Copying env files from main checkout`);
  copyEnv("web/.env", mainRoot, worktreePath);
  copyEnv("relay/.env", mainRoot, worktreePath);

  // --- 3. TS deps (hoisted to worktree root) ---
  run("bun", ["install"], worktreePath, "bun install (all workspaces)");

  // --- 3b. Prisma client — generated, gitignored, needed for web tests/typecheck.
  // Done explicitly rather than via web's postinstall: bun skips postinstall when
  // `bun install` reports no changes, which leaves the client missing.
  run("bun", ["run", "--filter", "antgrid-web", "prisma:generate"], worktreePath, "prisma generate (web client)");

  // --- 4. Migrate the shared local Postgres (idempotent) ---
  if (opts.db) {
    run("bun", ["run", "--filter", "antgrid-web", "migrate"], worktreePath, "prisma migrate deploy");
  } else {
    console.log("\n→ Skipping prisma migrate (--no-db)");
  }

  // --- 5. Flutter deps ---
  if (opts.flutter) {
    run("flutter", ["pub", "get"], resolve(worktreePath, "app"), "flutter pub get");
  } else {
    console.log("\n→ Skipping flutter pub get (--no-flutter)");
  }

  // --- Optional: full seed (dev user + Pro subscription) ---
  if (opts.seed) {
    run("bun", ["run", "scripts/dev-setup.ts"], worktreePath, "dev-setup (seed dev user + Pro sub)");
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));

  // Resolve the MAIN checkout from git (NOT this script's path — the script is a
  // tracked file and exists inside every worktree too).
  const mainRoot = resolve(dirname(git(["rev-parse", "--path-format=absolute", "--git-common-dir"])));
  const currentRoot = resolve(git(["rev-parse", "--show-toplevel"]));
  const worktreeParent = join(mainRoot, ".claude/worktrees");

  console.log("=== Antgrid worktree setup ===");

  if (!opts.name) {
    // --- Set-up-current mode ---
    if (norm(currentRoot) === norm(mainRoot)) {
      console.error(
        "\nYou're in the main checkout — nothing to set up here.\n" +
        "Pass a <name> to create a new worktree, or run this from inside a worktree.",
      );
      process.exit(1);
    }
    console.log(`  mode:    set up current worktree`);
    console.log(`  path:    ${currentRoot}`);
    provision(currentRoot, mainRoot, opts);
    finish(currentRoot, mainRoot);
    return;
  }

  // --- Create mode ---
  const branch = opts.branch!;
  const worktreePath = join(worktreeParent, opts.name);
  console.log(`  mode:    create new worktree`);
  console.log(`  name:    ${opts.name}`);
  console.log(`  branch:  ${branch}`);
  console.log(`  path:    ${worktreePath}`);

  if (existsSync(worktreePath)) {
    console.log(`\n→ Worktree dir already exists — skipping \`git worktree add\`, continuing setup.`);
  } else {
    mkdirSync(worktreeParent, { recursive: true });
    const addArgs = ["worktree", "add", worktreePath];
    if (branchExists(branch)) {
      addArgs.push(branch); // attach existing branch (no -b, which would error)
    } else {
      addArgs.push("-b", branch, ...(opts.from ? [opts.from] : []));
    }
    run("git", addArgs, mainRoot, "git worktree add");
  }

  provision(worktreePath, mainRoot, opts);
  finish(worktreePath, mainRoot);
}

function finish(worktreePath: string, mainRoot: string): void {
  console.log("\n=== Worktree ready ===\n");
  console.log(`  cd ${worktreePath}`);
  console.log("\nRun tests:");
  console.log("  bun test                         # from bridge/ relay/ web/ evals/");
  console.log("  bun run --filter='*' test        # all TS workspaces");
  console.log("  cd app && flutter test           # app");
  if (norm(worktreePath) !== norm(mainRoot)) {
    console.log("\nRemove when done:");
    console.log(`  git worktree remove ${worktreePath}`);
  }
}

main().catch((err) => {
  console.error("\nworktree setup failed:", err);
  process.exit(1);
});
