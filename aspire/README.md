# Antgrid AppHost (Aspire prototype)

Experimental replacement for `npm run dev` / `scripts/dev.ts`. Boots
web + relay + agent (and a Postgres container) under the Aspire
dashboard so logs and OTel traces are queryable in one place.

The Flutter desktop app is orchestrated too (`flutter run -d windows`), so
the whole stack comes up with one `aspire run`. Its interactive r/R/q
hot-reload menu doesn't work under Aspire (no child TTY) — use the dashboard
restart button, IDE save-to-reload, or the Dart MCP server (see below).

You can also launch the **Android** app alongside (or instead of) the desktop
one for exercising the relay path end-to-end — see [App targets](#app-targets).

## One-time setup

1. Install the Aspire CLI: https://aspire.dev/get-started/install-cli/
2. From this directory, scaffold the Aspire runtime (generates `.modules/`,
   `tsconfig.apphost.json`, `aspire.config.json`):
   ```pwsh
   aspire init
   ```
   If `init` insists on creating a starter template, run
   `aspire new aspire-ts-starter -o .` instead and delete the generated
   `apphost.ts` (keep the one in this repo).
3. Install TypeScript locally — Aspire shells out to `tsc` to compile
   `apphost.ts` and won't fall back to a global install:
   ```pwsh
   npm install
   ```
4. Make sure the rest of the dev environment is bootstrapped (unchanged):
   ```pwsh
   cd ..
   npm run setup
   cd aspire
   ```
   This still owns: per-service `.env` files, shared
   `RELAY_INTERNAL_SECRET`, prisma migrations, seeded dev license JWT.
   Aspire orchestrates processes — it does not regenerate secrets.

## Run

```pwsh
aspire run
```

The dashboard URL (with auth token) is printed on stdout. Open it for:
- live stdout/stderr per service (the headline win over `scripts/dev.ts`)
- resource graph + restart buttons
- OTel traces and metrics — once each service exports them (see below)

The Flutter app starts as the `app-windows` resource — no second terminal needed.

## App targets

Which Flutter apps Aspire launches is controlled by `ANTGRID_APP_TARGETS`
(comma-separated; default `windows`). Each target becomes its own dashboard
resource (`app-<target>`) with independent logs and Hot-reload command. This is
the easy way to drive the **relay** from two clients at once — desktop and a
phone — against the same local web/relay.

```pwsh
aspire run                                   # windows only (default)

# From the repo root — convenience scripts set the flag cross-platform:
npm run aspire:macos                         # macOS desktop app only
npm run aspire:android                       # Android emulator only
npm run aspire:ios                           # iOS simulator only
npm run aspire:all                           # windows + android, side by side
npm run aspire:mac:all                       # macOS desktop + iOS, side by side

# Or set the flag directly:
$env:ANTGRID_APP_TARGETS = "windows,android"; aspire run
```

Targets: `windows` and `macos` (desktop hosts — they spawn local agents) and
`android` / `ios` (remote relay clients — they can't spawn a local agent, so
they carry only the dart-defines pointing them at the host's relay/web).

**Android prerequisites**
- An Android **emulator (AVD) must be booted before `aspire run`** — flutter
  errors "no devices" otherwise. (`flutter emulators --launch <id>`.)
- Every target reaches the relay through the dev machine's **LAN IP**, which
  apphost.ts auto-detects (`pickLanIp`) and bakes into `RELAY_URL`. Android also
  receives that LAN host in `LICENSE_API_URL` so an emulator or physical phone
  can reach web. Desktop targets use `localhost` for `LICENSE_API_URL`, keeping
  the OAuth start and callback on Better Auth's cookie origin. The relay/web
  bind `0.0.0.0`, so both host forms reach the same local services.
- **Override with `ANTGRID_LAN_IP=<ip>`** when detection picks the wrong adapter
  (common on Windows — WSL/Hyper-V/Docker virtual NICs). apphost logs the chosen
  host on startup; if none is found it falls back to `localhost` (host-only).
- The LAN IP over plain http would trip the app's insecure-transport guard, so
  `AuthService` permits RFC-1918 private ranges **in debug builds only**.
- Windows firewall must allow inbound on the relay/web ports for a phone (or the
  host's own LAN-routed connection) to reach them.
- The default device filter is `-d emulator` (flutter's `-d` matches a device
  id/name, not a platform, and AVD ids are always `emulator-NNNN`). If several
  emulators/devices are attached, pin one with `ANTGRID_ANDROID_DEVICE=<id>`
  (e.g. `emulator-5556`, or a physical device's serial — passed to
  `flutter run -d <id>`).

**iOS prerequisites** (macOS host only)
- An iOS **simulator must be booted before `aspire run`** (`xcrun simctl boot
  <udid>` + `open -a Simulator`, or launch one from Xcode) — flutter errors "no
  devices" otherwise. A physical iPhone also works if it's trusted and connected.
- The default device filter is `-d iphone` (flutter's `-d` matches a device
  id/name, not a platform; simulators surface as their model name, e.g.
  "iPhone 16 Pro"). If several iOS devices are booted, pin one with
  `ANTGRID_IOS_DEVICE=<udid-or-name-substring>` (e.g. an "iPad" substring).
- The iOS simulator shares the host's network, so it can reach the relay/web on
  the LAN IP baked into the dart-defines (`localhost` would also work on the
  simulator, but the LAN IP keeps every target on one host value).
- First launch runs `pod install` and an Xcode build, so it's slow; simulator
  builds need no code-signing.

### Hot reload

Each `app-<target>` resource has its own **Hot reload** command (the resource's
`⋯` menu in the dashboard). It reloads changed Dart sources into the running app
without a full restart — the equivalent of pressing `r` in `flutter run`, which
Aspire children can't receive (no TTY).

How it works: `flutter run` is launched in `--machine` mode through
`scripts/flutter-launcher.mjs`. The launcher translates flutter's daemon JSON
stream back into readable dashboard logs, owns flutter's stdin, and runs a
localhost control server whose port it writes to a per-target control file
(`aspire/.flutter-control-<target>`). The
command POSTs to that server, which sends the Flutter daemon
`app.restart {fullRestart:false}` request — flutter's own compiler does the
reload. Click it before the app has started and it returns "App isn't running
yet — start it before hot reloading"; just retry once the app is up.

Why not the simpler routes:
- Raw VM-Service `reloadSources` fails for Flutter apps ("Error while starting
  Kernel isolate task") — the `flutter` tool, not the VM, owns the incremental
  compiler, so reload has to go through the daemon.
- The POSIX `--pid-file` + SIGUSR1 hot-reload trick doesn't exist on Windows
  (the target here is `-d windows`).

## Driving the Flutter app via the Dart MCP server

Aspire launches the app externally, so the Dart MCP server can't see it via
`launch_app` / `list_running_apps`. Connect to it through its Dart Tooling
Daemon (DTD) instead. Under `--machine`, flutter delivers the DTD URI as an
`app.dtd` daemon event (not the plain `--print-dtd` stdout line), so
`scripts/flutter-launcher.mjs` translates that event into a log line.

1. `aspire run`
2. Get the DTD URI from the relevant **`app-<target>`** resource's logs (e.g.
   `app-windows`) — either scroll for the line below, or grep it server-side:
   ```
   [flutter] Dart Tooling Daemon available at: ws://127.0.0.1:<port>/<token>=
   ```
   ```pwsh
   aspire logs app-windows --search "Tooling Daemon"
   ```
3. Connect the Dart MCP server to that URI (its `connect_dart_tooling_daemon`
   tool). Then `hot_reload`, `hot_restart`, `get_widget_tree`,
   `get_runtime_errors`, and `flutter_driver` all work against the running app.

Notes:
- The URI (port + token) changes every launch. If you stop/restart the
  `app-<target>` resource from the dashboard, re-copy the new URI and reconnect.
- This keeps Flutter inside Aspire. The alternative — dropping it from
  `apphost.ts` and letting the MCP own it via `launch_app` (which returns the
  DTD URI directly) — trades away the dashboard's log/restart integration.

## Caveats / known gaps

- **OTel traces require SDK wiring per service.** Aspire injects
  `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_SERVICE_NAME` into each child,
  but bridge/relay/web don't currently import an OTel SDK. Logs
  (stdout capture) work immediately; spans need
  `@opentelemetry/sdk-node` + `@opentelemetry/auto-instrumentations-node`
  initialised at the top of each entrypoint. Worth doing once you've
  decided Aspire is staying.
- **Postgres connection string.** `withReference(db)` injects
  `ConnectionStrings__antgrid`; the env callback re-publishes it as
  `PG_DATABASE_URL` to match `web/src/env.ts`. If you'd rather
  point web at a long-lived local Postgres, drop the `addPostgres`
  block and let the per-service `.env` win.
- **Bun services use first-party `addBunApp`.** As of Aspire 13.4 the
  `Aspire.Hosting.JavaScript` package provides `addBunApp(name, dir, script)`
  directly, so web/relay/agent are registered with
  `addBunApp(...).withRunScript("dev")` (each runs its `bun run dev` script).
  This replaced the old `addNodeApp(...).withBun()` from the CommunityToolkit
  NodeJS extensions, which is no longer a dependency.
- **`scripts/dev.ts` stays.** This is a parallel option, not a
  replacement, until we're confident in the dashboard experience.
