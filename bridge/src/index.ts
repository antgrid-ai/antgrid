import { Command } from "commander";
import { join } from "node:path";
import type { Level } from "pino";
import { logger, setLogLevel } from "./logger";
import { consoleBootstrapIO, writeConfigYaml, buildConfigFromBootstrap } from "./bootstrap";
import { startPerfLog } from "./perf-log";
import { readBootstrapPayload } from "./auth/credentials";
import { VERSION } from "./version";
import { HostServer } from "./host-server";
import { resolveAbDir } from "./antgrid-dir";
import { startOwnerWatchdog } from "./owner-watchdog";
import { augmentHostPath } from "./host-path";
import { runHookInvocation } from "./hook-runner";

// Component-tagged child for this module's own lifecycle logs.
const log = logger.child({ component: "bridge" });

const VALID_LEVELS = new Set<string>(["trace", "debug", "info", "warn", "error", "fatal"]);

// Re-exported for tests/protocol.test.ts, which imports it from `./index`.
export { buildAgentHello } from "./agent-core";

// --- Bun version check ---
function checkBunVersion(minVersion: string): void {
  const current = (globalThis as any).Bun?.version;
  if (!current) return; // Not running in Bun — skip check

  const parse = (v: string) => v.split(".").map(Number);
  const [cMaj, cMin, cPatch] = parse(current);
  const [mMaj, mMin, mPatch] = parse(minVersion);

  if (
    cMaj < mMaj ||
    (cMaj === mMaj && cMin < mMin) ||
    (cMaj === mMaj && cMin === mMin && cPatch < mPatch)
  ) {
    console.error(`Antgrid Agent requires Bun >= ${minVersion} (current: ${current})`);
    console.error("Upgrade with: curl -fsSL https://bun.sh/install | bash");
    process.exit(1);
  }
}

checkBunVersion("1.3.5");

const program = new Command()
  .name("antgrid")
  .description("Antgrid Agent — terminal streaming agent")
  .version(VERSION);

program
  .command("hook")
  .description("Run an internal Antgrid agent hook")
  .argument("<agent>")
  .argument("<event>")
  .argument("[payload]")
  .action(async (agent: string, event: string, payload?: string) => {
    await runHookInvocation({ agent, event, payload });
    // Exit explicitly: hooks are advisory and must never linger. An agent that
    // holds this process's stdin open (copilot does) would otherwise keep the
    // event loop alive until its own hook timeout kills us. Matches the deleted
    // node scripts, which all force-exited 0.
    process.exit(0);
  });

// Single default action — reads bootstrap payload from stdin, branches on mode.
program
  .option("--verbose", "Alias for --log-level debug")
  .option("--log-level <level>", "trace|debug|info|warn|error|fatal (env: ANTGRID_LOG_LEVEL)")
  .option("--debug-perf", "Sample RSS at 1Hz to ~/.antgrid/perf.log")
  .action(async (opts: { verbose?: boolean; logLevel?: string; debugPerf?: boolean }) => {
    // Precedence: explicit --log-level, then ANTGRID_LOG_LEVEL, then --verbose alias.
    const level = opts.logLevel ?? process.env.ANTGRID_LOG_LEVEL ?? (opts.verbose ? "debug" : undefined);
    if (level) {
      if (VALID_LEVELS.has(level)) setLogLevel(level as Level);
      else log.warn(`ignoring invalid log level "${level}"`);
    }

    let payload;
    try {
      payload = await readBootstrapPayload();
    } catch (err) {
      console.error(`antgrid-bridge: ${(err as Error).message}`);
      process.exit(64); // EX_USAGE
    }

    const host = new HostServer({
      ...(payload.machine
        ? {
            remote: {
              relayUrl: payload.machine.relayUrl,
              licenseApiUrl: payload.machine.licenseApiUrl,
              identity: {
                deviceId: payload.machine.auth.deviceUuid,
                deviceName: payload.machine.auth.deviceUuid,
                createdAt: new Date().toISOString(),
                ed25519PublicKey: payload.machine.auth.ed25519Pub,
                ed25519PrivateKey: payload.machine.auth.ed25519Priv,
              },
              auth: {
                clientId: payload.machine.auth.clientId,
                clientSecret: payload.machine.auth.clientSecret,
                deviceUuid: payload.machine.auth.deviceUuid,
              },
              onAuthRevoked: () => {
                process.stderr.write(`${JSON.stringify({ event: "auth_revoked" })}\n`);
                process.exit(4);
              },
            },
          }
        : {}),
      ...(payload.ownerBuild ? { ownerBuild: payload.ownerBuild } : {}),
      // The app sends `host:shutdown` when its window closes; reuse the same
      // graceful path as SIGTERM (defined below) so PTYs are killed cleanly.
      onShutdownRequested: () => void shutdown("app-close"),
    });

    await host.startControlPlane();    // bind loopback control + write host.json

    // RSS sampler runs for the whole host process when --debug-perf is set —
    // started here (not gated on a first project) so a machine-only warm-up
    // spawn that only ever serves project:open RPCs is still sampled. Labelled
    // by the first project when one is opened inline below.
    const perfLog = opts.debugPerf
      ? startPerfLog(payload.firstProject?.projectId ?? "warmup")
      : null;
    process.once("exit", () => { try { perfLog?.stop(); } catch {} });

    let isShuttingDown = false;
    const shutdown = async (reason?: string) => {
      if (isShuttingDown) return;
      isShuttingDown = true;
      log.info("Shutting down%s...", reason ? ` (${reason})` : "");
      perfLog?.stop();
      await host.shutdown(reason);
      process.exit(0);
    };

    // Wire teardown BEFORE the (possibly multi-second) first-project open, so an
    // owner death or signal mid-open can't leave the host registered on the
    // relay for an app that's already gone. The owner-watchdog self-exits when
    // the spawning app's pid vanishes — the backstop for exits that never reach
    // the app's didRequestAppExit teardown (force-kill, crash, or a window close
    // under `flutter run --machine`), which would otherwise orphan this
    // machine-level host.
    if (payload.ownerPid !== undefined) {
      startOwnerWatchdog({
        ownerPid: payload.ownerPid,
        onOwnerGone: (reason) => void shutdown(reason),
      });
    }
    process.on("SIGINT", () => shutdown("SIGINT"));
    process.on("SIGTERM", () => shutdown("SIGTERM"));
    process.on("SIGHUP", () => shutdown("SIGHUP"));
    process.on("uncaughtException", (err) => { log.error("Uncaught exception: %s", err); shutdown("uncaughtException"); });
    process.on("unhandledRejection", (err) => { log.error("Unhandled rejection: %s", err); shutdown("unhandledRejection"); });

    // Inline the first project when one was provided. An eager warm-up spawn
    // (app launch) sends no firstProject — the control plane is already up from
    // startControlPlane() above; the host then waits for project:open RPCs.
    // A remote first project lazily mints the machine token here
    // (HostServer.open → ensureRemoteRuntime); a mint failure surfaces as a
    // throw and exits non-zero below.
    if (payload.firstProject) {
      try {
        await host.open(payload.firstProject.projectId, payload.firstProject.projectPath, payload.firstProject.mode);
      } catch (err) {
        console.error(`antgrid-bridge: failed to open first project: ${(err as Error).message}`);
        process.exit(1);
      }
    }
  });

// antgrid init subcommand — regenerate antgrid.yaml from the current workspace.
program
  .command("init")
  .description("Regenerate antgrid.yaml from the current workspace")
  .action(async () => {
    const { existsSync } = await import("node:fs");
    const path = join(process.cwd(), "antgrid.yaml");
    if (existsSync(path)) {
      const { confirm } = await import("@inquirer/prompts");
      const ok = await confirm({ message: `${path} already exists. Regenerate?`, default: false });
      if (!ok) { console.log("Aborted."); return; }
    }
    const cfg = await buildConfigFromBootstrap({ cwd: process.cwd(), io: consoleBootstrapIO() });
    writeConfigYaml(path, cfg);
    console.log(`Written to ${path}. Open this project in the Antgrid desktop app — it launches and manages the bridge for you.`);
  });

// antgrid phones subcommand — inspect and drop local phone records. Whether a
// phone may drive this machine is one machine-wide switch (mobile-access), not
// anything this CLI manages.
program
  .command("phones")
  .description("Inspect trusted phones and drop their local records")
  .argument("[verb]", "list | remove")
  .argument("[target]", "Phone ref (remove)")
  .option("--phone <ref>", "Phone pubkey, deviceId, or label")
  .action(async (verb?: string, target?: string, opts?: { phone?: string }) => {
    const { loadPairedPhones } = await import("./paired-phones");
    const { phonesList, phonesRemove } = await import("./cli/phones");

    const abDir = resolveAbDir();
    // This CLI resolves ANTGRID_DIR from its own shell env, which is only
    // correct when it matches whatever env the target host was started with
    // (e.g. a dev host launched via `npm run dev`/`npm run aspire` runs on
    // ~/.antgrid-dev, not this default) — printed so a mismatch is visible
    // instead of a silent success the running host never sees.
    console.error(`[antgrid phones] using ${join(abDir, "agents", "paired-phones.json")}`);
    const store = loadPairedPhones(abDir);

    let code = 1;
    switch (verb ?? "list") {
      case "list":
        code = phonesList(store);
        break;
      case "remove": {
        const ref = opts?.phone ?? target;
        if (!ref) { console.error("usage: antgrid phones remove <phone> | --phone <ref>"); break; }
        code = phonesRemove(store, ref, abDir);
        break;
      }
      default:
        console.error(`unknown verb "${verb}". Use: list | remove`);
        code = 1;
    }
    process.exit(code);
  });

if (import.meta.main) {
  // A GUI launch (Finder/Dock) hands the host a stripped PATH that misses the
  // profile dirs where agents install; recover it before the action resolves a
  // binary or memoizes tool detection. Gated on import.meta.main so a plain
  // import (e.g. tests pulling buildAgentHello) never mutates global PATH.
  // No-op on Windows. See host-path.ts.
  augmentHostPath();
  await program.parseAsync();
}
