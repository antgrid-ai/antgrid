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
import { initCrashReporting, captureBridgeError, flushCrashReports } from "./crash-reporting";

// Component-tagged child for this module's own lifecycle logs.
const log = logger.child({ component: "bridge" });

const VALID_LEVELS = new Set<string>(["trace", "debug", "info", "warn", "error", "fatal"]);

/** Ceiling on the whole teardown, from the first signal to `process.exit`.
 *  Sits above everything `HostServer.shutdown` budgets for itself — the 5s
 *  graceful ask for every terminal, then the tree kills behind it — so it only
 *  ever fires for a stall nothing else bounds. */
const SHUTDOWN_HARD_LIMIT_MS = 20_000;

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
    // Deliberately NOT crash-reported. A hook is spawned by the agent CLI, not
    // by the app, so it is handed no bootstrap payload and there is no consent
    // to act on — and the two costs land on a path the agent blocks on for
    // every tool use: SDK init on entry, and a transport flush before an exit
    // that is otherwise immediate. The field failure this would seem to catch
    // (a hook that never runs at all — see the MSIX `<Application>` note in
    // CLAUDE.md) is a CreateProcess denial, which no in-process SDK can observe.
    await runHookInvocation({ agent, event, payload });
    // Exit explicitly: hooks are advisory and must never linger. An agent that
    // holds this process's stdin open (copilot does) would otherwise keep the
    // event loop alive until its own hook timeout kills us. Matches the deleted
    // node scripts, which all force-exited 0.
    process.exit(0);
  });

// Internal executor for a managed checkout's `worktree.setup`: the bridge
// re-invokes ITSELF under the setup PTY. The shipped bridge is a compiled
// single-file executable and cannot `bun run` a script, so a subcommand is the
// only self-invocation that works — the same shape `resolveHookCommand` relies
// on. Hidden: nothing about it is user-facing.
program
  .command("worktree-setup", { hidden: true })
  .description("Run a resolved worktree setup plan")
  .requiredOption("--plan <file>", "Path to the resolved setup plan JSON")
  .action(async (opts: { plan: string }) => {
    const { runWorktreeSetupCli } = await import("./cli/worktree-setup");
    process.exit(await runWorktreeSetupCli({ plan: opts.plan }));
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

    // First thing after the payload, because the payload is where consent
    // arrives — nothing before this point is reportable, which is the honest
    // answer rather than a gap to close. Absence of the flag is OFF: a host
    // started by the CLI or a test has nobody who consented to anything.
    if (
      initCrashReporting({
        enabled: payload.telemetryEnabled ?? false,
        dsn: process.env.SENTRY_DSN ?? "",
        release: payload.ownerBuild,
      })
    ) {
      log.debug("crash reporting enabled");
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
                // Through the same teardown as every other exit. Exiting here
                // directly ran no shutdown code at all: on Windows the kernel
                // still swept each PTY as it closed our job handles, but POSIX
                // has no such backstop and every agent tree was orphaned.
                void shutdown("auth-revoked", 4);
              },
            },
          }
        : {}),
      ...(payload.ownerBuild ? { ownerBuild: payload.ownerBuild } : {}),
      // The app sends `host:shutdown` when its window closes; reuse the same
      // graceful path as SIGTERM (defined below) so PTYs are killed cleanly.
      onShutdownRequested: () => void shutdown("app-close"),
    });

    // RSS sampler runs for the whole host process when --debug-perf is set —
    // started here (not gated on a first project) so a machine-only warm-up
    // spawn that only ever serves project:open RPCs is still sampled. Labelled
    // by the first project when one is opened inline below.
    const perfLog = opts.debugPerf
      ? startPerfLog(payload.firstProject?.projectId ?? "warmup")
      : null;
    process.once("exit", () => { try { perfLog?.stop(); } catch {} });

    let isShuttingDown = false;
    // Recorded rather than passed through, because the verdict can arrive
    // DURING a shutdown already in flight: token maintenance runs to the last
    // moment, and a revocation that lost that race would exit 0 and tell the
    // app's supervisor to respawn straight back into the dead credential pair.
    let exitCode = 0;
    const shutdown = async (reason?: string, code = 0) => {
      if (code !== 0) exitCode = code;
      if (isShuttingDown) return;
      isShuttingDown = true;
      log.info("Shutting down%s...", reason ? ` (${reason})` : "");
      perfLog?.stop();
      // The exit is the one thing this function owes: `onAuthRevoked` used to
      // call `process.exit(4)` outright, and routing it through the teardown
      // makes that exit conditional on a multi-second async path that asks
      // every agent to leave. A shutdown that throws would otherwise land in
      // the `unhandledRejection` handler above, be swallowed by the
      // `isShuttingDown` guard, and hang the process on a dead credential pair;
      // one that merely stalls hangs it just as well. So bound it and exit
      // regardless — an unswept tree is worse than nothing only until the
      // kernel closes our job handles, which is exactly what a Windows exit
      // does anyway.
      const bail = setTimeout(() => {
        log.warn("Shutdown exceeded %dms; exiting anyway", SHUTDOWN_HARD_LIMIT_MS);
        process.exit(exitCode);
      }, SHUTDOWN_HARD_LIMIT_MS);
      try {
        await host.shutdown(reason);
      } catch (err) {
        log.error("Shutdown failed: %s", err);
        captureBridgeError(err, "shutdown");
      }
      // After the drain, not before: this is the last chance to send whatever
      // the SDK's top-level handlers queued. ~15ms when there is nothing to
      // send, so a clean exit is not measurably slower for a consenting host.
      await flushCrashReports();
      clearTimeout(bail);
      process.exit(exitCode);
    };

    // Wire teardown BEFORE the control plane comes up, so an owner death or a
    // signal during bring-up or the first-project open can't leave the host
    // registered on the relay for an app that's already gone. `host.shutdown()`
    // is null-safe against a host that never started, which is what lets this
    // sit ahead of it. The owner-watchdog self-exits when the spawning app's
    // pid vanishes — the backstop for exits that never reach
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
    // These own the EXIT; Sentry's own handler for each owns the CAPTURE (it is
    // installed by initCrashReporting above), which is what keeps a fatal marked
    // `handled: false` rather than re-reported here as an ordinary handled
    // error — so there is deliberately no captureBridgeError call in either.
    //
    // **These must be registered for as much of the process's life as possible.**
    // The SDK decides whether to exit on its own AT CRASH TIME, by counting the
    // OTHER uncaughtException listeners: with one of ours present it defers and
    // this teardown sweeps the PTYs; as the sole listener it logs and
    // `process.exit(1)`s, skipping the sweep. Hence the order below: everything
    // between initCrashReporting and here is straight-line setup that opens
    // nothing, whereas startControlPlane publishes host.json and only THEN
    // spends seconds on the relay handshake and OAuth mint — with host.json on
    // disk the app can drive project:open over loopback for that whole stretch,
    // so it is not a window in which "no PTY exists yet" may be assumed.
    process.on("uncaughtException", (err) => { log.error("Uncaught exception: %s", err); shutdown("uncaughtException"); });
    process.on("unhandledRejection", (err) => { log.error("Unhandled rejection: %s", err); shutdown("unhandledRejection"); });

    await host.startControlPlane();    // bind loopback control + write host.json

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
        // Reported explicitly: this exit is a bare process.exit, so it reaches
        // neither the shutdown path's flush nor either top-level handler, and a
        // mint failure against a revoked credential pair lands here and nowhere
        // else.
        captureBridgeError(err, "first-project-open");
        await flushCrashReports();
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

// antgrid watch subcommand — live capture of both wires this machine owns: the
// relay socket, and the loopback socket a co-located desktop app rides. Reads
// host.json for the control port + token, so it attaches to the ALREADY-RUNNING
// host rather than starting anything.
program
  .command("watch")
  .description("Stream relay and loopback frames from the running host (connection debugging)")
  .option("--json", "Emit raw JSONL instead of the rendered table")
  .option("--export <file>", "Append raw JSONL to a file as well")
  .option("--limit <n>", "Buffered events to replay before following (default 200)")
  .option("--no-follow", "Print the buffered snapshot and exit")
  .option("--dir <path>", "ANTGRID_DIR of the target host (debug builds use ~/.antgrid-dev)")
  .option("--join <file>", "Pair this capture against an app-side netwatch.log (implies --no-follow)")
  .option("--remote", "Ask the connected app to capture its side and ship it here (the only way to reach a phone)")
  .option("--local", "Show only loopback frames — the transport a desktop app on this machine uses")
  .option("--relay", "Show only relay frames — the transport a phone uses")
  .option("--bodies", "Record loopback frame plaintext while this runs (truncated per frame; metadata is always recorded)")
  .action(async (opts: { json?: boolean; export?: string; limit?: string; follow?: boolean; dir?: string; join?: string; remote?: boolean; local?: boolean; relay?: boolean; bodies?: boolean }) => {
    const { runNetwatchCli } = await import("./cli/netwatch");
    const limit = opts.limit === undefined ? undefined : Number(opts.limit);
    if (limit !== undefined && (!Number.isFinite(limit) || limit <= 0)) {
      console.error("antgrid watch: --limit must be a positive number");
      process.exit(1);
    }
    process.exit(await runNetwatchCli({ ...opts, limit }));
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
