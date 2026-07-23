/**
 * Starts all Antgrid services for local development.
 *
 * Startup order matters: web owns the JWKS the relay verifies
 * against and the device-token endpoints the agent calls. We boot it
 * first and gate the rest on `/health` so relay/app don't race ahead
 * and log spurious errors during the first 1-3s.
 *
 * Usage: bun run scripts/dev.ts
 */

import { homedir } from "node:os";
import { join } from "node:path";

const LICENSE_API_URL = process.env.LICENSE_API_URL ?? "http://localhost:8787";
const HEALTH_TIMEOUT_MS = 30_000;

// Isolate the dev stack's Antgrid home (pairing, relay-epoch, sessions, auth)
// from an installed release app on ~/.antgrid so the two never collide. Set
// here so it flows through `start()`'s `...process.env` to the debug app, which
// resolves it via hostDir() and hands it to the spawned host — both agree.
// Home-relative (NOT repo-local) so it matches hostDir()'s own bare-debug-build
// default (app/lib/launcher/host_discovery.dart) — a plain `flutter run` with no
// launcher lands on the same directory as this script. Honors an explicit
// override (e.g. a developer pointing at a scratch dir).
process.env.ANTGRID_DIR ??= join(homedir(), ".antgrid-dev");
console.log(`[antgrid] ANTGRID_DIR=${process.env.ANTGRID_DIR}`);

// Spawn bun directly (not via a .cmd wrapper) so the App's
// LocalAgentLauncher avoids the visible cmd.exe popup on Windows.
const agentBin = process.execPath; // e.g. C:\...\bun.exe on Windows
const agentScript = `${import.meta.dir}/../bridge/src/index.ts`;

interface ServiceSpec {
  name: string;
  cmd: string[];
  cwd: string;
  env?: Record<string, string>;
  /**
   * Whether the child needs an interactive TTY on stdin. Default: false.
   *
   * Bun's `--watch` mode (used by web's dev:server) tries to put
   * stdin into Windows' win32-input-mode (DEC private mode 9001) so it
   * can read keypresses for restart commands. Bun's node-stream compat
   * layer doesn't fully implement that mode and prints
   *     warning(stream): unimplemented mode: 9001
   * on every spawn. Routing stdin to "ignore" for non-interactive
   * services suppresses it without affecting Flutter, whose hot-reload
   * menu legitimately needs stdin keypresses.
   */
  interactive?: boolean;
}

const procs: { name: string; proc: ReturnType<typeof Bun.spawn> }[] = [];

function start({ name, cmd, cwd, env, interactive = false }: ServiceSpec) {
  const proc = Bun.spawn(cmd, {
    cwd: `${import.meta.dir}/../${cwd}`,
    stdout: "inherit",
    stderr: "inherit",
    stdin: interactive ? "inherit" : "ignore",
    env: { ...process.env, ...(env ?? {}) },
  });
  console.log(`[antgrid] Started ${name} (pid ${proc.pid})`);
  procs.push({ name, proc });
  return proc;
}

let killing = false;
function killAll() {
  if (killing) return;
  killing = true;
  for (const { name, proc } of procs) {
    if (proc.exitCode !== null) continue;
    console.log(`[antgrid] Stopping ${name} (pid ${proc.pid})...`);
    if (process.platform === "win32" && proc.pid) {
      // Bun.spawn.kill() on Windows only signals the direct child. Our children
      // are `bun run dev` wrappers that fork grandchildren (concurrently, vite,
      // watchers) which would otherwise be orphaned and keep ports bound.
      // taskkill /T walks the tree; /F is required because the grandchildren
      // ignore the soft close.
      try {
        Bun.spawnSync(["taskkill", "/PID", String(proc.pid), "/T", "/F"], {
          stdout: "ignore",
          stderr: "ignore",
        });
      } catch {
        proc.kill();
      }
    } else {
      proc.kill();
    }
  }
}

process.on("SIGINT", () => { killAll(); process.exit(130); });
process.on("SIGTERM", () => { killAll(); process.exit(143); });
process.on("exit", () => { killAll(); });
process.on("uncaughtException", (err) => {
  console.error("[antgrid] uncaughtException:", err);
  killAll();
  process.exit(1);
});

async function waitForHealth(url: string, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  let lastErr: unknown = null;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${url}/health`);
      if (res.ok) return;
      lastErr = `status ${res.status}`;
    } catch (err) {
      lastErr = err;
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error(`web /health not ready within ${timeoutMs}ms: ${lastErr}`);
}

// 1. web first — relay JWKS + agent token refresh both depend on it.
start({ name: "web", cmd: ["bun", "run", "dev"], cwd: "web" });

console.log(`[antgrid] Waiting for web at ${LICENSE_API_URL}/health ...`);
try {
  await waitForHealth(LICENSE_API_URL, HEALTH_TIMEOUT_MS);
  console.log("[antgrid] web is healthy.");
} catch (err) {
  console.error(`[antgrid] ${(err as Error).message}`);
  killAll();
  process.exit(1);
}

// 2. Now safe to fan out the dependents.
// On Windows, `flutter` ships as `flutter.bat`; Bun.spawn doesn't auto-resolve
// PATHEXT, so spawning bare "flutter" ENOENTs. Use the .bat name on win32.
const flutterBin = process.platform === "win32" ? "flutter.bat" : "flutter";

try {
  start({ name: "relay", cmd: ["bun", "run", "dev"], cwd: "relay" });
  start({
    name: "app",
    cmd: [flutterBin, "run", "-d", "windows"],
    cwd: "app",
    interactive: true, // Flutter's hot-reload menu (r / R / q) reads stdin
    env: {
      ANTGRID_AGENT_BIN: agentBin,
      ANTGRID_AGENT_PREARGS: agentScript,
    },
  });
} catch (err) {
  console.error(`[antgrid] Failed to start service: ${(err as Error).message}`);
  killAll();
  process.exit(1);
}

// Wait for any to exit, then take down the rest.
const results = await Promise.race(
  procs.map(async ({ name, proc }) => {
    const code = await proc.exited;
    return { name, code };
  })
);

console.log(`[antgrid] ${results.name} exited with code ${results.code}, stopping others...`);
killAll();

process.exit(results.code);
