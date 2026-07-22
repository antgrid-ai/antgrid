// Antgrid AppHost — Aspire orchestrator for web + relay.
//
// Replaces the Bun-launched fan-out in scripts/dev.ts with Aspire's resource
// graph so the services stream logs (and OTel traces, once each service
// wires the SDK) into the Aspire dashboard. The Flutter app is orchestrated
// too — one resource per selected device target (ANTGRID_APP_TARGETS, default
// windows; see "Flutter apps" below) — with a dashboard "Hot reload" command
// since Aspire children have no TTY for flutter's r/R/q menu.
//
// Run:
//   aspire run                                  # windows app (default)
//   ANTGRID_APP_TARGETS=macos aspire run        # macOS desktop app
//   ANTGRID_APP_TARGETS=ios aspire run          # iOS simulator app
//   ANTGRID_APP_TARGETS=windows,android aspire run   # both, for relay testing (npm run aspire:all)
//   ANTGRID_APP_TARGETS=macos,ios aspire run    # mac desktop + iOS (npm run aspire:mac:all)
//   dashboard URL printed on stdout
//
// One-time bootstrap is unchanged:
//   npm run setup         # generates per-service .env + dev license JWT
//
// Aspire only orchestrates processes here; each service loads its own .env from
// disk — including web's PG_DATABASE_URL, which must point at an externally-run
// Postgres (e.g. a local install or Postgres.app). Aspire does NOT manage a
// Postgres container, so `aspire run` needs no container runtime.

import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { networkInterfaces } from "node:os";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createBuilder,
  refExpr,
  EndpointProperty,
  type EnvironmentCallbackContext,
  type ExecuteCommandResult,
} from "./.modules/aspire.js";
import { licenseApiHostForTarget, type AppTarget } from "./target-hosts.js";

// Absolute path to the agent entrypoint. MUST be absolute: LocalAgentLauncher
// spawns the agent with `workingDirectory` set to the *opened project folder*,
// so a relative prearg (e.g. "../bridge/src/index.ts") would resolve against
// that folder and fail with "Module not found" for any project that isn't a
// sibling of the antgrid repo. scripts/dev.ts uses an absolute path for the same
// reason; this mirrors it.
const aspireDir = dirname(fileURLToPath(import.meta.url));
const agentScript = resolve(aspireDir, "..", "bridge", "src", "index.ts");

// Wrapper that launches `flutter run --machine` and exposes a localhost
// control server (see scripts/flutter-launcher.mjs). The "Hot reload" command
// below POSTs to that server, which sends the Flutter daemon `app.restart`
// request over flutter's stdin — the supported hot-reload path (raw VM-Service
// reloadSources fails for Flutter: the `flutter` tool owns the compiler).
const flutterLauncher = resolve(aspireDir, "scripts", "flutter-launcher.mjs");

// Each Flutter app resource gets its own control file so the windows and
// android apps don't clobber each other's launcher port (the dashboard
// "Hot reload" command reads the per-app file to reach that app's launcher).
function controlFileFor(target: AppTarget): string {
  return resolve(aspireDir, `.flutter-control-${target}`);
}

// Reads the launcher's control-server port, or null if the app hasn't started
// its server yet (still booting, or stopped).
function readControlPort(controlFile: string): number | null {
  if (!existsSync(controlFile)) return null;
  const raw = readFileSync(controlFile, "utf8").trim();
  const port = Number(raw);
  return Number.isInteger(port) && port > 0 ? port : null;
}

// Triggers a hot reload via the launcher's control server. The timeout bounds
// the call so a wedged flutter daemon can't hang the dashboard command forever
// (the launcher's own daemon timeout is shorter, so it normally replies first).
async function triggerHotReload(port: number): Promise<ExecuteCommandResult> {
  const resp = await fetch(`http://127.0.0.1:${port}/reload`, {
    method: "POST",
    signal: AbortSignal.timeout(60_000),
  });
  const body = (await resp.json()) as { success: boolean; message?: string };
  return body.success
    ? { success: true, message: body.message ?? "Hot reload complete." }
    : { success: false, errorMessage: body.message ?? "Hot reload failed." };
}

// Aspire compiles + runs the apphost under Node, so process.execPath is node.
// LocalAgentLauncher needs bun.exe — resolve it from PATH instead.
function resolveBun(): string {
  const cmd = process.platform === "win32" ? "where bun" : "command -v bun";
  const out = execSync(cmd, { encoding: "utf8" }).split(/\r?\n/)[0]?.trim();
  if (!out) throw new Error("bun not found on PATH — install bun or set ANTGRID_BUN_BIN");
  return out;
}
const bunBin = process.env.ANTGRID_BUN_BIN ?? resolveBun();

// Sets one env var on a resource to an Aspire reference expression (connection
// string, allocated endpoint, …). Used by the callbacks below so web
// and relay don't each re-spell the get-environment→set-ref dance.
async function setEnvRef(
  ctx: EnvironmentCallbackContext,
  name: string,
  value: unknown,
): Promise<void> {
  const env = await ctx.environment();
  await env.set(name, refExpr`${value}`);
}

const builder = await createBuilder();

// Single source of truth for web's port. The pin below, the LAN token audience,
// and (transitively) the app's licenseApiPort all derive from this, so they
// can't drift: change it in one place and the minted OAuth `resource` still
// matches the accepted audience.
const WEB_PORT = 8787;

// Single source of truth for the relay's port under Aspire: the endpoint pin
// below and web's RELAY_INTERNAL_URL both derive from it, so they can't drift.
// Deliberately NOT relay/.env's PORT=8080 (which scripts/dev.ts still uses) —
// the pin injects PORT, so the relay listens here under `aspire run`.
const RELAY_PORT = 3000;

// Computed up-front (before the web resource) so web can accept the LAN-IP
// token audience — see pickLanIp() and the web EXTRA_TOKEN_AUDIENCES wiring.
const lanHost = pickLanIp();
console.log(
  lanHost === "localhost"
    ? "[apphost] no LAN IP found — relay/mobile web use localhost (mobile won't reach the host; set ANTGRID_LAN_IP)"
    : `[apphost] relay and mobile web targets use ${lanHost} (override with ANTGRID_LAN_IP)`,
);

// web — relay JWKS + agent token refresh both depend on this.
// Postgres is NOT Aspire-managed: web reads PG_DATABASE_URL from its own .env
// (must point at an externally-run Postgres). So no withReference(db)/waitFor(db)
// and no connection-string override here.
const licenseApi = await builder
  .addBunApp("web", "../web", "src/index.ts")
  .withBun({ install: false })
  .withRunScript("dev")
  // Pin to WEB_PORT — web's OAuth callbacks, JWT issuer claim, and the
  // relay/agent/app defaults all assume this fixed port. targetPort + isProxied
  // false makes Aspire bind web directly to it (no proxy hop).
  .withHttpEndpoint({ port: WEB_PORT, targetPort: WEB_PORT, env: "PORT", isProxied: false })
  .withEnvironmentCallback(async (ctx: EnvironmentCallbackContext) => {
    // web/.env's RELAY_INTERNAL_URL is generated for `npm run dev`, where the
    // relay honours relay/.env's PORT=8080. Under `aspire run` the pin below
    // injects RELAY_PORT instead, so that .env value points at nothing and
    // /internal/{revoke,expire} silently degrades to TTL — the push is
    // best-effort and only warns, so a device revoke appears to succeed while
    // the relay never learns. Loopback, not lanHost: this hop is machine-local,
    // and a LAN IP goes stale the moment the host changes network.
    await setEnvRef(ctx, "RELAY_INTERNAL_URL", `http://127.0.0.1:${RELAY_PORT}`);

    // Mobile apps mint license tokens with `resource=${LICENSE_API_URL}/api/auth`,
    // and their LICENSE_API_URL is the LAN IP so they can reach web.
    // The oauth-provider validates that resource against its accepted audiences,
    // which default to BETTER_AUTH_URL (localhost) only — so widen them to also
    // accept the LAN-IP audience. The JWT *issuer* stays BETTER_AUTH_URL, so
    // relay verification and OAuth callbacks are unaffected. Uses WEB_PORT (the
    // same source the app's licenseApiPort resolves from) so the audience can't
    // drift from the minted resource. Skipped when no LAN IP (localhost already
    // covered by the default audience).
    if (lanHost !== "localhost") {
      await setEnvRef(ctx, "EXTRA_TOKEN_AUDIENCES", `http://${lanHost}:${WEB_PORT}/api/auth`);
    }
  });

// relay — verifies license JWTs against web's JWKS endpoint.
// Aspire assigns web a dynamic port via withHttpEndpoint, so the
// stale LICENSE_API_URL=http://localhost:8787 in relay/.env points at nothing.
// Override it here from the Aspire-allocated endpoint so apphost is the
// source of truth when running under `aspire run`.
const licenseApiHttp = await licenseApi.getEndpoint("http");
const relay = await builder
  .addBunApp("relay", "../relay", "src/index.ts")
  .withBun({ install: false })
  .withRunScript("dev")
  // Pin to RELAY_PORT (the relay's conventional default) and bind directly, NOT
  // behind Aspire's proxy. A proxied endpoint's DCP reverse-proxy listens on
  // loopback only, so the published port is unreachable on the LAN IP — the
  // app/host (and any phone) then can't open ws://<lanIp>:<port>/ws. With
  // isProxied:false + targetPort, Bun binds 0.0.0.0:RELAY_PORT itself (same
  // pattern as web on 8787), making it LAN-reachable. PORT is injected for
  // loadConfig().
  .withHttpEndpoint({ port: RELAY_PORT, targetPort: RELAY_PORT, env: "PORT", isProxied: false })
  .withReference(licenseApi)
  .waitFor(licenseApi)
  .withEnvironmentCallback((ctx: EnvironmentCallbackContext) =>
    setEnvRef(ctx, "LICENSE_API_URL", licenseApiHttp),
  );

// Capture the relay endpoint (pinned to 3000 above) and inject its host:port
// into the Flutter app below via the same dart-define route as LICENSE_API_URL.
// It's an http URL — both the Dart relay client and the bridge's
// joinRelayWsPath upgrade http(s)→ws(s) and append /ws.
const relayHttp = await relay.getEndpoint("http");

// The agent is not orchestrated by Aspire — the Flutter app spawns it per
// opened project via LocalAgentLauncher (see ANTGRID_AGENT_* on the app resource
// below), so a standalone agent process here would be redundant.

// Flutter apps — one resource per selected device target. Default is the
// windows desktop app (unchanged); `ANTGRID_APP_TARGETS=windows,android` (or
// `android` alone) opts the Android app in for relay testing, side by side in
// the dashboard. Each target gets its own logs, control file, and Hot-reload
// command. See README "App targets".
//
// The desktop apps (windows, macos) host local projects (they spawn agents via
// LocalAgentLauncher, hence ANTGRID_AGENT_*); the mobile apps (android, ios) are
// purely remote relay clients — they can't spawn a local agent, so they carry
// none of that env, only the dart-defines pointing them at the host's relay/web.
const KNOWN_TARGETS: readonly AppTarget[] = ["windows", "macos", "android", "ios"];
const isDesktopTarget = (t: AppTarget): boolean =>
  t === "windows" || t === "macos";

function parseTargets(raw: string | undefined): AppTarget[] {
  if (!raw || !raw.trim()) return ["windows"];
  const wanted = raw
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  const result: AppTarget[] = [];
  for (const t of wanted) {
    if (!KNOWN_TARGETS.includes(t as AppTarget)) {
      throw new Error(
        `ANTGRID_APP_TARGETS: unknown target "${t}" (expected ${KNOWN_TARGETS.join("|")})`,
      );
    }
    if (!result.includes(t as AppTarget)) result.push(t as AppTarget);
  }
  return result.length ? result : ["windows"];
}

const appTargets = parseTargets(process.env.ANTGRID_APP_TARGETS);
const flutterBin = process.platform === "win32" ? "flutter.bat" : "flutter";

// The endpoints' ports as Aspire reference expressions, so the Android
// dart-defines can swap the host to 10.0.2.2 (the AVD's alias for the dev
// machine — the device's own `localhost` is the emulator, not the host) while
// reusing the same Aspire-allocated ports the desktop app talks to.
const licenseApiPort = await licenseApiHttp.property(EndpointProperty.Port);
const relayPort = await relayHttp.property(EndpointProperty.Port);

// Host address mobile targets use to reach web and every target uses for the
// relay. `localhost` resolves to the device on mobile, while the LAN IP works
// for emulators, physical phones, and phones paired from the desktop's QR.
// Desktop OAuth is the exception: its browser must start on localhost so the
// host-only state cookie returns to Better Auth's localhost callback.
//
// Detection is best-effort and a frequent footgun on Windows (WSL/Hyper-V/
// Docker virtual NICs masquerade as the LAN), so ANTGRID_LAN_IP overrides it;
// falling back to localhost preserves the pre-LAN desktop-only behavior.
//
// Whatever this returns gets baked into the app's LICENSE_API_URL dart-define,
// which AuthService._transportIsSecure (auth_service.dart) trusts verbatim in
// debug builds regardless of address range — the value is developer-supplied
// at launch, not attacker-reachable, so it doesn't need to look like a "real"
// RFC-1918 address (some networks put dev machines on a routed public-looking
// range). Keep that trust boundary in mind before loosening this further.
function pickLanIp(): string {
  const override = process.env.ANTGRID_LAN_IP?.trim();
  if (override) return override;
  const candidates: string[] = [];
  for (const addrs of Object.values(networkInterfaces())) {
    for (const a of addrs ?? []) {
      if (a.family === "IPv4" && !a.internal) candidates.push(a.address);
    }
  }
  // Prefer common home/office ranges; 172.x is usually a virtual bridge.
  const rank = (ip: string) =>
    ip.startsWith("192.168.") ? 0 : ip.startsWith("10.") ? 1 : 2;
  candidates.sort((a, b) => rank(a) - rank(b));
  return candidates[0] ?? "localhost";
}

for (const target of appTargets) {
  const controlFile = controlFileFor(target);
  const licenseApiHost = licenseApiHostForTarget(target, lanHost);
  // flutter's `-d` matches a device id/name (substring), NOT a platform — so
  // `-d android`/`-d ios` find nothing. AVD ids are always `emulator-NNNN`, so
  // `-d emulator` resolves the running Android emulator; override with
  // ANTGRID_ANDROID_DEVICE (e.g. a physical device's serial, or a specific
  // `emulator-5556`) when several are attached. iOS simulators surface as their
  // model name (e.g. "iPhone 16 Pro"), so `-d iphone` matches the booted
  // simulator; override with ANTGRID_IOS_DEVICE (a UDID or an "iPad" substring)
  // when several are booted. The AVD/simulator must be booted before
  // `aspire run` — flutter errors "no devices" otherwise.
  // Desktop targets ("windows"/"macos") match a `flutter -d` device of the same
  // name, so the target string is the device id directly.
  const deviceId =
    target === "android"
      ? process.env.ANTGRID_ANDROID_DEVICE ?? "emulator"
      : target === "ios"
        ? process.env.ANTGRID_IOS_DEVICE ?? "iphone"
        : target;

  // Builder methods return a chainable PromiseLike (awaited once at the end);
  // reassign rather than await mid-chain so the conditional desktop-only env
  // composes without resolving the builder early.
  let app = builder
    // Launch flutter through scripts/flutter-launcher.mjs (run under this same
    // Node) rather than directly: the wrapper runs `flutter run --machine`,
    // translates the daemon JSON stream back into readable dashboard logs, and
    // hosts the control server the "Hot reload" command talks to.
    // process.execPath is the Node running the apphost, so we don't depend on
    // `node` being on PATH. --machine is required for the daemon protocol; the
    // launcher surfaces the Dart Tooling Daemon URI from the `app.dtd` daemon
    // event (for the Dart MCP connect_dart_tooling_daemon flow), and --print-dtd
    // is kept as a belt-and-suspenders hint to flutter to start the DTD.
    .addExecutable(`app-${target}`, process.execPath, "../app", [
      flutterLauncher,
      flutterBin,
      "run",
      "--machine",
      "-d",
      deviceId,
      "--print-dtd",
    ])
    .withEnvironment("ANTGRID_FLUTTER_CONTROL", controlFile)
    .waitFor(licenseApi)
    .waitFor(relay);

  if (isDesktopTarget(target)) {
    // ANTGRID_AGENT_* match scripts/dev.ts so LocalAgentLauncher finds bun +
    // the agent entrypoint for projects opened in the desktop app.
    app = app
      .withEnvironment("ANTGRID_AGENT_BIN", bunBin)
      .withEnvironment("ANTGRID_AGENT_PREARGS", agentScript)
      // Diagnostic: tee the app-spawned bridge/host logs to a file (the host's
      // stdout is otherwise buried under flutter+aspire). Inherited by the host
      // child via LocalAgentLauncher. Remove once same-account pairing is sorted.
      .withEnvironment("ANTGRID_DEBUG_LOG", resolve(aspireDir, "..", "bridge-debug.log"))
      // DCP injects SSL_CERT_DIR/SSL_CERT_FILE pointing at its private dev-cert
      // dir (no public root CAs) into every orchestrated process. That
      // propagates down to spawned agents and breaks any tool honoring the
      // OpenSSL cert override — e.g. Codex's rustls WebSocket transport fails
      // public TLS with UnknownIssuer while the OS-native HTTPS stack (schannel
      // on Windows, Secure Transport on macOS) still works. Tell the bridge to
      // strip those overrides for child PTYs so they use the system trust store.
      // Dev-only: this flag is never set by the shipped app.
      .withEnvironment("ANTGRID_STRIP_INHERITED_CERT_OVERRIDES", "1");
  }

  // The Flutter app reads LICENSE_API_URL/RELAY_URL via `String.fromEnvironment`
  // (Dart compile-time constants), so a process env var won't reach them — they
  // must be `--dart-define` flags on `flutter run`. waitFor(licenseApi) above
  // ensures the endpoints are allocated before these args resolve.
  app = app
    .withArgsCallback(async (ctx) => {
      const args = await ctx.args();
      // Desktop auth stays on localhost to share its cookie origin with Better
      // Auth's callback. Mobile targets need the LAN host to reach the web API.
      await args.add(refExpr`--dart-define=LICENSE_API_URL=http://${licenseApiHost}:${licenseApiPort}`);
      await args.add(refExpr`--dart-define=RELAY_URL=http://${lanHost}:${relayPort}`);
    })
    // Dashboard button → sends the Flutter daemon `app.restart` (hot reload).
    // Replaces the dead `r` keypress (no TTY for Aspire children).
    .withCommand(
      "hot-reload",
      "Hot reload",
      async (): Promise<ExecuteCommandResult> => {
        const port = readControlPort(controlFile);
        if (!port) {
          return {
            success: false,
            errorMessage: "App isn't running yet — start it before hot reloading.",
          };
        }
        try {
          return await triggerHotReload(port);
        } catch (err) {
          return {
            success: false,
            errorMessage: err instanceof Error ? err.message : String(err),
          };
        }
      },
      {
        commandOptions: {
          description: "Hot reload changed Dart sources into the running app.",
          iconName: "ArrowClockwise",
        },
      },
    );

  await app;
}

await builder.build().run();
