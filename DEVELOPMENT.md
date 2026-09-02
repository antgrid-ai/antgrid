# Development

How to build, run and test Antgrid from source.

Be warned: the toolchain is heavy. Antgrid is four components in two languages —
a Bun/TypeScript bridge and relay, a Bun/TypeScript web service on Postgres, and
a Flutter app that ships to Windows, macOS, Linux, Android and iOS. A full stack
build touches all of it.

The good news is that you almost never need all of it. Most contributions touch
one component, and each one builds and tests on its own. Read
[Pick your scope](#pick-your-scope) first and install only what that column asks
for.

This guide is for building and changing the code, whether you are working in a
fork or on the project itself. [CONTRIBUTING.md](CONTRIBUTING.md) covers what to
do with a change once you have one — currently: external pull requests are not
open yet, and bug reports are the thing that helps.

---

## Pick your scope

| I want to work on | I need |
|---|---|
| `packages/antgrid-wire` — frame codec, relay envelope schemas | Bun |
| `relay/` — routing, auth, epochs, rate limiting, the licence gate | Bun |
| `bridge/` — PTYs, file watching, git, port scanning, tunnelling | Bun |
| `web/` — accounts, subscriptions, JWT minting | Bun + Postgres |
| `site/` — the Astro marketing site | Bun (not a root workspace: `cd site && bun install`) |
| `app/` — all Flutter UI | Flutter SDK |
| `packages/antgrid_relay_client`, `packages/antgrid_eval_client` | Dart SDK |
| A **Windows desktop build** of the app | Flutter + Visual Studio C++ workload + a JDK |
| A **macOS desktop build** | Flutter + Xcode |
| A **Linux desktop build** | Flutter + the apt list below |
| An **Android build** | Flutter + JDK 17 + Android SDK (+ Rust and NDK r28+ to pass the Play alignment gate) |
| The **full stack running end to end** | Bun + Postgres + Flutter + one desktop toolchain |

Running `flutter test` and `flutter analyze` needs only the Flutter SDK — no
platform toolchain. You can do the majority of app work that way. One caveat: the
first run resolves the `portable_pty` / `ghostty_vte` native assets,
which downloads prebuilt libraries from GitHub and falls back to building the
Rust crate if that download fails — so behind a proxy or offline you will also
need a Rust toolchain.

---

## Prerequisites

### Everyone

**Bun** — the minimum is **1.3.5**, checked at startup in
`bridge/src/index.ts`; below it the bridge prints
`Antgrid Agent requires Bun >= 1.3.5` and exits. Install **1.3.14 or newer**
anyway: the relay's iOS push transport requires 1.3.14 (1.3.10 fails the APNs
sandbox TLS handshake), and 1.3.14 is what this tree is developed against. CI
pins a floating `1.3`.

```bash
curl -fsSL https://bun.sh/install | bash
bun --version
```

On Windows, use the installer on [bun.sh](https://bun.sh) instead.

**Git**, obviously.

**Node and npm** are optional. The only `engines` field in the repo is
`aspire/package.json` (`^20.19.0 || ^22.13.0 || >=24`), and that applies to the
Aspire launcher only. No root script needs Node or npm to execute — `bun run
<script>` runs the same body as `npm run <script>`, so the two are
interchangeable everywhere in this document. `npm` is used in the examples
because that is what the scripts are named for.

### Postgres — `web/` only

CI uses `postgres:16-alpine`, which is the safe choice locally too. The setup
script defaults to:

```
postgres://postgres:postgres@localhost:5432/antgrid
```

Docker is the quickest route:

```bash
docker run -d --name antgrid-pg -p 5432:5432 \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=antgrid \
  postgres:16-alpine
```

The role you connect as needs **CREATEDB**. The web test suite migrates one
template database and then clones it per test file with
`CREATE DATABASE … TEMPLATE`; a role without that privilege fails at the first
test. The default `postgres` superuser has it.

`web/.env.example` shows a different database name (`antgrid_license`) from what
`scripts/dev-setup.ts` writes (`antgrid`). The setup script is what actually
runs — trust the value in the generated `web/.env`.

Prisma 6 is invoked through `bunx`, so there is nothing to install globally. The
generated client lands in `web/src/generated/prisma/`, which is gitignored and
produced by the root `postinstall`. **A fresh clone must run `bun install`
before anything imports the database layer**, including `npm run setup` itself.

### Flutter and Dart — `app/` and the Dart packages

The SDK constraint is `sdk: ^3.11.0` (Dart 3.11 or newer, below 4.0) in
`app/pubspec.yaml` and both packages under `packages/`. CI pins Flutter
**3.47.1 stable**, repeated across the workflows and `scripts/setup-cloud.sh`
and kept in lockstep — grep `flutter-version` and `FLUTTER_VERSION` to find
every copy before bumping. Any stable Flutter whose bundled Dart satisfies
`^3.11.0` should work; if you hit something odd, match the CI pin before filing
a bug.

```bash
flutter --version
cd app && flutter pub get
```

### Windows — desktop builds

Two things, and the second one surprises people.

**1. Visual Studio 2022 or newer with the "Desktop development with C++"
workload.** `app/windows/CMakeLists.txt` asks only for CMake 3.14, so that
number tells you nothing — the real floor comes from the Flutter plugins this
app pulls in. Visual Studio 2019, whose bundled CMake is 3.20, fails. Visual
Studio 2022 or newer is the requirement; VS 18 2026 with its bundled CMake 4.3.1
is what has actually been measured working.

**2. A full JDK.** This is not optional and it is not obvious. `sentry_flutter`
pulls in the transitive `jni` package, `jni` declares Windows support, so every
CMake configure of the Windows runner executes `find_package(JNI)`. Without a
JDK the link fails with:

```
LNK1104: cannot open file 'jvm.lib'
```

Any full JDK works. On Windows:

```powershell
winget install Microsoft.OpenJDK.21
```

That installer sets `JAVA_HOME` itself. GitHub's `windows-latest` runner
installs no JDK explicitly and still builds, because the runner image ships one
— your machine will not.

Install the JDK **before** your first `flutter build windows`. A failed first
configure leaves a permanent mess; see
[Trap 1](#trap-1-a-failed-windows-cmake-configure-poisons-appbuild-permanently).

**Shell.** Commands in this file are written for a POSIX shell. On Windows, Git
Bash or WSL runs them as written. In PowerShell 5.1, `&&` is a parser error —
chain with `;` instead. One script is bash-only regardless of how you invoke it:
`npm run check:font-tokens` shells out to `bash app/scripts/check_font_tokens.sh`
and will not run under PowerShell or cmd.

**Symlinks.** Every `AGENTS.md` in this repo is a symlink to the `CLAUDE.md`
beside it, so an agent looking for the vendor-neutral name reads the same file.
Windows has supported symlinks since Vista and needs no elevation once Developer
Mode is on — the obstacle is Git's own default. Unless "Enable symbolic links"
was ticked during installation, Git for Windows writes `core.symlinks=false` into
its system config, and a clone made under that setting materialises every symlink
as a one-line text file holding the target path. That stub reads as ordinary
content instead of failing, so a dangling or unresolved link can sit unnoticed
for a long time.

```bash
git config --global core.symlinks true
```

Set it **before** cloning: a clone records the value in its own `.git/config` and
keeps it thereafter. To repair an existing clone, set it there as well, then
delete the stub files and `git checkout -- .` so git writes real links.

### macOS — desktop and iOS builds

No extra system packages. A working Xcode toolchain plus the standard Flutter
macOS setup is enough; CI builds the macOS desktop app with nothing beyond
Flutter and Bun.

The desktop app targets **macOS 12 and up** — Flutter 3.47 dropped Big Sur. The
floor is set in `app/macos/Podfile` and in every `MACOSX_DEPLOYMENT_TARGET` in
`app/macos/Runner.xcodeproj/project.pbxproj`; those two must agree. Sparkle's
`minimumSystemVersion` is read out of the built app rather than hardcoded (see
the appcast step in `build-desktop.yml`), so raising the floor again means those
two files and nothing else.

iOS simulator builds need no code signing, but a simulator must be **booted
before** you start the app or Flutter errors with "no devices":

```bash
xcrun simctl boot <udid> && open -a Simulator
```

First iOS launch runs `pod install` and a full Xcode build, so budget time.

### Linux — desktop builds

Beyond the base Flutter Linux toolchain, this app's plugins need a handful of
development packages. From the CI recipe:

```bash
sudo apt-get update
sudo apt-get install -y \
  ninja-build libgtk-3-dev pkg-config clang cmake \
  libwebkit2gtk-4.1-dev \
  libsecret-1-dev libayatana-appindicator3-dev \
  libcurl4-openssl-dev
```

Why each one:

- `ninja-build`, `libgtk-3-dev`, `pkg-config`, `clang`, `cmake` — the base
  `flutter build linux` toolchain.
- `libwebkit2gtk-4.1-dev` — the WebKitGTK engine the preview webview embeds.
- `libsecret-1-dev` — backing store for `flutter_secure_storage_linux`.
- `libayatana-appindicator3-dev` — tray/indicator support pulled by the GTK shell.
- `libcurl4-openssl-dev` — `sentry_flutter`'s bundled `sentry-native` looks for
  CURL for its HTTP transport.

`libfuse2` and `zsync` appear in CI too, but only for AppImage packaging. A
normal development build does not need them.

One Linux behaviour to expect rather than debug: the preview webview draws on
top of Flutter widgets. WebKitGTK cannot render offscreen-to-texture, so
`app/linux/runner/my_application.cc` uses a native `GtkOverlay`. This is
documented in `app/pubspec.yaml` and is by design.

### Android

- **JDK 17** (Temurin in CI).
- **Android SDK** with a recent build-tools and platform.
- Gradle **8.14** (via the wrapper), AGP **8.11.1**, Kotlin **2.2.20** — pinned
  in `app/android/settings.gradle.kts` and the Gradle wrapper properties. Do not
  let an IDE "upgrade" them; the AndroidX graph hard-requires AGP ≥ 8.9.1 and
  Gradle's built-in Kotlin migration downgrades KGP below Flutter's floor.
- Core library desugaring is required (`flutter_local_notifications`); it is
  already wired in `app/android/app/build.gradle.kts`.

Optional: **Rust (rustup + cargo)**, because `super_clipboard` →
`super_native_extensions` compiles its crate from source whenever no precompiled
binary matches the target ABI; and an **NDK**, whose `llvm-readelf` is how you
check ELF alignment by hand. See
[Trap 4](#trap-4-a-16-kb-alignment-failure-is-never-fixed-by-bumping-the-ndk).

`app/android/local.properties` is generated by the Flutter tool and is not in
the repo. Running Gradle before Flutter has generated it fails with
`flutter.sdk not set in local.properties`. Run `flutter pub get` in `app/`
first.

### Optional: the Aspire launcher

`npm run aspire` runs the stack under the Aspire dashboard. It needs the Aspire
CLI (the repo pins SDK 13.4.0 in `aspire/aspire.config.json`) and a one-time
scaffold. It does **not** need a container runtime — Postgres is not
Aspire-managed here, contrary to some older comments in `aspire/README.md`.
Details under [Running the stack](#running-the-stack).

---

## Known traps

Read these before your first build. Each one has cost real hours, and each looks
like a different problem than it is.

### Trap 1: a failed Windows CMake configure poisons `app/build/` permanently

**Symptom.** A clean compile that then dies during INSTALL with
`cannot create directory … Maybe need administrative privileges`. It reads like
a file-permissions problem. It is not, and running as administrator does not fix
it.

**Why.** In `app/windows/CMakeLists.txt`, `include(flutter/generated_plugins.cmake)`
comes *before* the install-prefix override, and that override is guarded by
`if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)` — a variable that is true only
on the **first** configure. So a single plugin error on the very first attempt
(a missing JDK will do it) leaves `CMAKE_INSTALL_PREFIX` pointing at
`C:/Program Files/antgrid`, and no later *successful* configure ever corrects
it. The build then tries to install into Program Files forever.

**Fix.** Fix the underlying plugin error first (usually: install a JDK), then
delete the build directory:

```bash
rm -rf app/build/windows
```

This trap is Windows-only, so you are most likely in PowerShell, where `rm -rf`
is not that command — `rm` resolves to `Remove-Item` and `-rf` matches no
parameter. There, use:

```powershell
Remove-Item -Recurse -Force app\build\windows
```

Re-running the build without deleting it cannot recover. `app/linux/CMakeLists.txt`
has the identical ordering, so Linux is exposed to the same class of failure.

### Trap 2: never run `flutter analyze` or `dart analyze` concurrently

**Symptom.** One invocation hangs forever, emitting nothing. No error, no
timeout.

**Why.** Flutter's launcher takes a startup lock in a sleepless retry loop with
stderr discarded, so the second invocation spins silently and never gives up.
`dart` calls the same launcher, so a `dart analyze` racing a `flutter analyze`
does it too.

**Fix.** Run one at a time. If your editor runs an analysis server in the
background, that counts — close it or wait before running an analyze from the
terminal.

### Trap 3: never run a bare `bun test` from the repo root

**Symptom.** A run that takes minutes, fails differently every time, and tells
you nothing.

**Why.** Bun's test runner walks the current directory recursively. From the
repo root that collects `evals/` alongside every unit suite. `evals/` is real
end-to-end machinery: it spawns actual bridge processes, starts a real relay
in-process, and drives real PTYs and loopback ports. Collapsing that into one
port space with the unit tests produces flakiness that is not a bug in anything
you changed. It will also descend into any nested checkout that happens to live
under the repo root.

**Fix.** Always name the workspace:

```bash
bun run --filter antgrid-bridge test
```

The root `npm run test` (`bun run --filter='*' test`) is **safe** — it dispatches
only into workspaces that declare a `test` script, and `evals/` deliberately
declares none. It does include `antgrid-web`, so it needs Postgres.

### Trap 4: a 16 KB alignment failure is never fixed by bumping the NDK

**Symptom.** A Play Store submission rejected for 16 KB page alignment, or the
`Verify 16 KB alignment` step in the Android workflows failing on a bundled
`.so`.

**Why.** Android 15 requires every 64-bit library in the bundle to have a max
LOAD `p_align` of at least `0x4000`. That comes from the flags the library was
**linked** with (`-Wl,-z,max-page-size=16384` plus `common-page-size`), not from
the NDK version — measured on `aarch64-linux-android`, NDK r27c emits `0x1000`
without them and `0x4000` with them. The app's native libraries arrive as
prebuilt binaries, so alignment is a property of the artifact and nothing in this
repo re-applies it.

**Fix.** Identify the offending library, then fix it in the release that
produced it (for the terminal libraries, see
[docs/dart-terminal-fork-release.md](docs/dart-terminal-fork-release.md)) — not
in the app:

```bash
llvm-readelf -lW <lib>   # every LOAD Align must be >= 0x4000
```

32-bit `armeabi-v7a` is exempt: 16 KB pages are a 64-bit-only feature. Leave
`jniLibs { useLegacyPackaging = false }` in `app/android/app/build.gradle.kts`
alone — that is zip alignment inside the APK, a separate requirement from
per-library ELF alignment.

### Trap 5: a debug app build talks to staging, not your local stack

**Symptom.** You start the full local stack, run the app, and cannot sign in.
Nothing in the logs points at the app.

**Why.** `app/lib/config/environment.dart` selects endpoints by build mode:
release builds target `relay.antgrid.ai` / `app.antgrid.ai`, and debug and
profile builds target the **staging** hosts. A bare `flutter run` silently talks
to staging, which you have no account on. Only an Aspire-launched app escapes
this — that resource carries both defines. Anything else, including the app
`npm run dev` starts on Windows, does not.

**Fix.** Pass both overrides, and match the relay port to your launcher:

```bash
cd app && flutter run -d windows \
  --dart-define=RELAY_URL=ws://localhost:3000 \
  --dart-define=LICENSE_API_URL=http://localhost:8787
```

That block is POSIX. In PowerShell — the likely shell for a `-d windows` build —
neither `&&` nor the trailing `\` works; use backtick continuations:

```powershell
cd app
flutter run -d windows `
  --dart-define=RELAY_URL=ws://localhost:3000 `
  --dart-define=LICENSE_API_URL=http://localhost:8787
```

Use `ws://localhost:3000` under `npm run aspire` and `ws://localhost:8080` under
`npm run dev` — see Trap 6.

### Trap 6: the relay listens on a different port under each launcher

Under `npm run aspire` the relay is pinned to **3000** (`RELAY_PORT` in
`aspire/apphost.ts`, injected as the child's `PORT`). Under `npm run dev` the
relay reads `relay/.env`, where setup writes **8080**. The web service is 8787
on both paths.

This is deliberate, not a bug, but it means a `RELAY_URL` copied from one set of
instructions silently fails under the other launcher. Check which launcher you
started.

### Trap 7: `bun install` refuses brand-new package versions

`bunfig.toml` sets `minimumReleaseAge = 1209600` and `.npmrc` sets
`min-release-age=14`. Any package version published in the last 14 days will not
install. If you add a dependency and Bun resolves an older version than you
asked for — or refuses outright — this is why. It is a supply-chain guard;
don't remove it to unblock yourself.

---

## First-time setup

From a fresh clone:

```bash
bun install     # from the repo root — one install covers every workspace
npm run setup   # per-service .env files, migrations, a seeded dev account
```

**`bun install` must come first.** The root `postinstall` generates the Prisma
client into `web/src/generated/prisma/`, and `npm run setup` imports the
database layer, which imports that generated client.

### What `npm run setup` needs to already exist

- Bun on `PATH`.
- A reachable Postgres. A failed migration prints
  `Migration failed. Is Postgres running and PG_DATABASE_URL correct?` and exits
  1.
- A prior `bun install`, per above.

### What it does

`scripts/dev-setup.ts`, in order:

1. Writes `web/.env`, filling only fields that are missing or empty.
2. Writes `relay/.env`, force-syncing `RELAY_INTERNAL_SECRET` to web's value.
3. Creates `relay/.env.example` if absent.
4. Runs `prisma migrate deploy` against `PG_DATABASE_URL`.
5. Seeds the plan table, a dev user `dev@antgrid.local`, and an active Pro
   subscription for it.
6. Registers a local Dart tooling entry in `.mcp.json`.

It is **idempotent**. Re-runs read the `.env` files and never rotate secrets;
only absent or empty keys are filled. Two self-heals are worth knowing about: a
`RELAY_INTERNAL_URL` not pointing at port 8080 is rewritten, and a
`RELAY_INTERNAL_SECRET` that has drifted between `web/.env` and `relay/.env` is
force-resynced.

`.mcp.json` is a **tracked** file, so `git status` may show it modified after
setup. The edit is additive and skips if the key already exists. Leave it or
revert it; either is fine.

### Credentials: none are required

No third-party account is needed for local development.

- `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_ID` and
  `GOOGLE_CLIENT_SECRET` are declared non-empty in `web/src/env.ts`, so setup
  fills them with literal stubs (`stub-github-client-id`, etc.). They must be
  *present*, not real. The consequence is that the GitHub and Google sign-in
  buttons render and then fail. Exercising those paths needs your own OAuth apps.
- **Sign-in still works, credential-free, via the magic link.** `ZEPTOMAIL_TOKEN`
  is optional and setup never fills it. With it unset, the email sender degrades
  to a console logger that prints the whole message:

  ```
  [email:dev] to=you@example.com subject=…
  ```

  Start the cross-device sign-in flow and copy the link out of the web server's
  stdout. This is the recommended way to run the full stack end to end without
  any accounts.
- Billing has three dev escape hatches: `DEV_BILLING_ENABLED=true` mounts
  `POST /dev/billing/subscription` and `POST /dev/billing/member` (both
  hard-gated to non-production), and `bun run scripts/dev-grant.ts <email>`
  grants Pro to a user created by a real sign-in. Setup seeds only
  `dev@antgrid.local`.

  `POST /dev/billing/member` takes `{email, ownerEmail, role?}` and moves
  `email` onto the account `ownerEmail` bills against — the only way to build a
  multi-member team until invites exist. It answers with the account's seat
  count and active headcount, so an **over-subscribed** account (more members
  than seats) can be constructed on purpose: that state is legal, blocks new
  invites only, and removes nobody. `seats` on
  `POST /dev/billing/subscription` sets the purchased count.

### Environment variables, if you want to set them by hand

The Zod schemas are the authority: `web/src/env.ts` and `relay/src/config.ts`.
The `.env.example` files are documentation and drift.

**`web/.env` — required** (no default, not optional; all filled by setup):
`PG_DATABASE_URL`, `BETTER_AUTH_SECRET` (≥16 chars), `GITHUB_CLIENT_ID`,
`GITHUB_CLIENT_SECRET`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`,
`CORS_ORIGINS`.

`CORS_ORIGINS` must list the **marketing site's** origin in staging and
production, not just the app's: `site/` is a static build on another host and its
founding-price capture POSTs to `/api/waitlist` here (`WEB_URL` in
`site/src/config.ts`). Omit it and every submit fails in the browser as a network
error, with nothing in the web service's logs to say why.

**`web/.env` — defaulted, safe to omit:** `NODE_ENV` (`development`),
`EMAIL_FROM`, `PORT` (8787). `BETTER_AUTH_URL` auto-derives to
`http://localhost:${PORT}` in development and test; it is required only in
staging and production.

**`web/.env` — optional:** `ZEPTOMAIL_TOKEN`, `ZEPTOMAIL_WEBHOOK_SECRET`,
`RELAY_INTERNAL_URL`, `RELAY_INTERNAL_SECRET`, the Paddle and Razorpay keys,
`IPINFO_TOKEN`, `DEV_BILLING_ENABLED`, `EXTRA_TOKEN_AUDIENCES`,
`TRUSTED_PROXY_IPS`.

**`relay/.env` — required:** `LICENSE_API_URL` and `RELAY_INTERNAL_SECRET`
(≥16 chars, and it must match web's). Both filled by setup.

**`relay/.env` — defaulted:** `PORT` (8080), `MAX_CONNECTIONS`, the rate-limit
knobs, `MAX_STREAMS_PER_CONNECTION`, `CLOCK_SKEW_MS` (120000),
`REPLAY_TTL_MS` (300000), the ping/pong timeouts, `LOG_LEVEL`,
`LICENSE_CACHE_MAX_ENTRIES`. One load-time invariant: `REPLAY_TTL_MS` must be
≥ `2 * CLOCK_SKEW_MS` or startup throws.

**`relay/.env` — push credentials are optional.** `FCM_PROJECT_ID` +
`FCM_CLIENT_EMAIL` + `FCM_PRIVATE_KEY` must be all set or all unset; a partial
triple throws at load (`relay/src/config.ts`). The APNs quartet (`APNS_KEY_ID`,
`APNS_TEAM_ID`, `APNS_PRIVATE_KEY`, `APNS_BUNDLE_ID`) is read without that
check, so a partial quartet leaves iOS push silently unconfigured rather than
failing fast — set all four or none. iOS direct-APNs also needs Bun ≥ 1.3.14.
Unconfigured push is fine; live in-band notifications still work.

**The bridge has no `.env` and needs none.** It receives its credentials as a
single JSON bootstrap payload written to stdin by the app when it spawns the
bridge. There is nothing to configure by hand.

---

## Running the stack

Three launchers. All of them assume `npm run setup` has already run — none of
them regenerate secrets.

### `npm run aspire` — the default

Runs `web` and `relay` plus one Flutter app resource per target, under the
Aspire dashboard with unified logs. The **bridge is deliberately not an Aspire
resource** — the Flutter app spawns it per opened project.

One-time setup, from `aspire/`:

1. Install the [Aspire CLI](https://aspire.dev/get-started/install-cli/).
2. `aspire init` — scaffolds `.modules/`, which is gitignored but imported by
   `apphost.ts`. Not optional on a fresh clone.
3. `npm install` — Aspire shells out to a *local* `tsc` and will not use a
   global one.

Then from the repo root:

```bash
npm run aspire            # windows app (default)
npm run aspire:macos
npm run aspire:android
npm run aspire:ios
npm run aspire:all        # windows + android side by side
npm run aspire:mac:all    # macos + ios side by side
```

Targets are controlled by `ANTGRID_APP_TARGETS` (comma-separated, default
`windows`). `windows` and `macos` are desktop hosts that spawn a local bridge;
`android` and `ios` are remote relay clients that cannot.

Mobile targets need more care:

- **The emulator or simulator must be booted before `aspire run`**, or Flutter
  errors with "no devices".
- The relay is reached over the dev machine's LAN IP, auto-detected. Override
  with `ANTGRID_LAN_IP=<ip>` when detection picks the wrong adapter — common on
  Windows because of WSL, Hyper-V and Docker virtual NICs.
- The Windows firewall must allow inbound connections on the relay and web
  ports.
- Pin a specific device with `ANTGRID_ANDROID_DEVICE` or `ANTGRID_IOS_DEVICE`
  when several are attached.

Flutter's interactive `r` / `R` / `q` menu does not work under Aspire (children
get no TTY). Use the per-resource **Hot reload** dashboard command instead.

### `npm run dev` — the fallback

`scripts/dev.ts` starts `web` first and gates everything else on
`${LICENSE_API_URL}/health` with a 30-second timeout — web owns the JWKS the
relay verifies against — then starts the relay and the Flutter app. It sets
`ANTGRID_DIR` to `~/.antgrid-dev` so the dev stack never collides with an
installed release app on `~/.antgrid`.

**It is hardcoded to `flutter run -d windows`.** So is `npm run dev:app`. On
macOS and Linux, use the per-service scripts and run Flutter yourself.

### Per-service

```bash
npm run dev:web      # web on 8787
npm run dev:relay    # relay on relay/.env's PORT (8080)
npm run dev:app      # Windows only — see above
```

There is no useful standalone bridge command. `npm run dev:agent` exists, but
the bridge reads a JSON bootstrap payload from stdin on startup and exits with a
usage error without one — the app writes that payload when it spawns the bridge.
Start the app and let it spawn the bridge for you.

On macOS or Linux, the app half becomes:

```bash
cd app && flutter run -d macos \
  --dart-define=RELAY_URL=ws://localhost:8080 \
  --dart-define=LICENSE_API_URL=http://localhost:8787
```

(`-d linux` on Linux.) A debug build with no `ANTGRID_AGENT_BIN` set falls back
to running the repo's `bridge/src/index.ts` through `bun`, so a bare
`flutter run` from a checkout finds the bridge without any environment setup.

### Pointing the app at your local stack

**Only if you launch the app yourself.** `npm run aspire` orchestrates the Flutter
app as its own resource and injects both dart-defines for you (`aspire/apphost.ts`
— it also rewrites the host to `10.0.2.2` for an Android target), so an
Aspire-launched app already points at the local stack. `npm run dev` launches the
app too, but only on Windows — and it passes **no** defines, so that app points at
staging like any other. Every case except an Aspire-launched app — `npm run dev`
on Windows, a bare `flutter run`, a desktop target on macOS or Linux, an app
started beside a per-service launcher — needs both defines passed by hand, and
the relay one must match the launcher's port. `npm run dev` gives you no way to
inject them, so to work against the local stack, start the services with it and
run the app yourself.

| Launcher you are running beside | `RELAY_URL` | `LICENSE_API_URL` |
|---|---|---|
| `npm run aspire` | `ws://localhost:3000` | `http://localhost:8787` |
| `npm run dev` / per-service | `ws://localhost:8080` | `http://localhost:8787` |

Getting this wrong is [Trap 5](#trap-5-a-debug-app-build-talks-to-staging-not-your-local-stack)
and [Trap 6](#trap-6-the-relay-listens-on-a-different-port-under-each-launcher);
it is the single most common way a first evening is wasted.

---

## Testing

### The commands

Bun workspace filter names are **not** the directory names — they come from each
`package.json`.

```bash
# TypeScript — no credentials, no database
bun run --filter antgrid-wire test
bun run --filter antgrid-relay test
bun run --filter antgrid-bridge test

# TypeScript — needs Postgres
bun run --filter antgrid-web test

# Flutter and Dart — subshells, so each line leaves you back at the repo root
(cd app && flutter test)
(cd packages/antgrid_relay_client && dart pub get && dart test)

# Static checks
npm run typecheck            # every TypeScript workspace
(cd app && flutter analyze)
npm run check:font-tokens    # bash only (Git Bash or WSL on Windows)

# End to end — explicit only, never in a sweep
bun run --filter antgrid-evals test:evals
```

Never a bare `bun test` from the root — see
[Trap 3](#trap-3-never-run-a-bare-bun-test-from-the-repo-root).

### What to run before you call a change done

Run whatever your change touches, plus the static checks for that language.
Concretely:

| Changed | Run |
|---|---|
| `packages/antgrid-wire` | its test suite, plus `bridge`, `relay` and `web` (they all consume it) |
| `bridge/` | `antgrid-bridge` test + `npm run typecheck` |
| `relay/` | `antgrid-relay` test + `npm run typecheck` |
| `web/` | `antgrid-web` test + `npm run typecheck` |
| `app/` | `flutter analyze` + `flutter test`, and `npm run check:font-tokens` for UI |
| `packages/antgrid_relay_client` | `dart pub get && dart analyze && dart test` in that directory |

Each Dart package needs its **own** `dart pub get` — the app's resolves into
`app/.dart_tool` only, and `flutter analyze` only walks the package it runs in.

### What CI actually gates

**CI** is the required check on `development` and `main`. It is deliberately not
path-filtered — GitHub reports a required check that never ran as pending forever
— so it runs on every pull request: the TypeScript workspace typechecks and test
suites, `dart test` for `antgrid_relay_client`, and the font-token check. It
touches no secret, so it passes from a fork.

Two more workflows run tests but are path-scoped, and therefore cannot be
required: **CI — web** (`web/**` and the root manifests, against a
`postgres:16-alpine` service) and **CI — android** (`app/**`, `packages/**` and
the PTY build script). A green mark from either says nothing unless your change
matched its filter.

CI — android ends in a release build whose shape depends on the diff: a PR that
touches `app/android`, either pubspec, or the Android toolchain gets the full
4-ABI AAB and the 16 KB ELF alignment gate, and anything else gets a single-ABI
release APK — enough to prove Dart AOT, tree-shaking, R8 and manifest merge,
which `flutter test` never exercises because it runs on the JIT VM. Push to
`main` always takes the full path.

**Deploy marketing site** builds and tests `site/` on pull requests targeting
`main`; only its deploy step is skipped on a fork PR, because GitHub correctly
withholds the credential. **Claude Code Review** is mention-triggered — comment
`/code-review` on a PR. It never runs on push, and a clean review posts nothing
at all, so silence from it means "no findings", not "did not run".

**Infra — OpenTofu** no longer runs here. `infra/` and `deploy/` moved to the
private ops repo, so nothing in this repository validates OpenTofu or can reach a
server; the deployment pipeline meets this repo only at the container registry.

**Not covered by CI:** `evals/`, which spawns real agents, relays and PTYs and so
cannot run on a fork — it stays on `bun run --filter antgrid-evals test:evals`.
`site/` is gated only on pull requests targeting `main`. For those your local run
is the only thing between the change and a broken integration branch. The
workflow set itself is the source of truth: `.github/workflows/`.

### Roughly how long each suite takes

Useful mainly for telling "hung" from "slow". Measured on one developer machine;
treat the numbers as orders of magnitude, not targets.

| Suite | Scale | External dependencies |
|---|---|---|
| `antgrid-wire` | 8 files, well under a second | none |
| `antgrid-relay` | 20 files, a few seconds | none — no `.env` needed |
| `antgrid-bridge` | 200+ files, well over a minute | none; spawns real PTYs and binds loopback ports in temp dirs |
| `app` (`flutter test`) | 260+ files | none beyond the Flutter SDK |

The bridge suite binding ports and spawning processes is expected, and it logs
warnings while passing. It needs no network access and nothing to sign into.

### The `evals/` suite

`evals/` is the end-to-end suite. It stands up its **own** in-process relay and
its **own** fake account API that mints a canned token, then spawns a real
bridge with locally generated keys over a stdin bootstrap payload. So contrary
to what you might expect, it needs **no antgrid.ai account, no deployed relay
and no licence server**.

What it does need:

- A machine tolerant of many real child processes, PTYs and loopback ports. On
  Windows the harness kills whole process trees, because a plain kill orphans
  PTY children that accumulate across suites.
- `dart` on `PATH` for the Dart-client end-to-end scenarios.
- Real agent CLIs for the chat-session tests. Those are gated on the binary
  being present — `claude`, `codex`, `opencode` — so without them you get clean
  **skips**, not failures. Each also needs to be logged in and carries its own
  subscription. The opencode suite additionally requires you to opt in with
  `ANTGRID_EVAL_OPENCODE_AUTH=1`.

No workflow runs `evals/`, on pull requests or otherwise — and a fork's CI could
not supply a logged-in agent CLI in any case. Maintainers run it explicitly:

```bash
bun run --filter antgrid-evals test:evals
```

---

## What you can work on without any credentials

Most of the repo. Being specific, because it decides whether a drive-by
contribution is possible at all.

**Zero credentials, zero accounts, no database:**

- **`packages/antgrid-wire`** — the frame codec, the relay control-envelope
  schemas, `FRAME_VERSION`, and the spoof-safe client-IP resolver shared by the
  relay and web. `bun run --filter antgrid-wire test`.
- **`relay/` in full** — hello verification order, epoch arbitration, the replay
  cache, routing authorization, stream admission, rate limiting, and the licence
  gate logic itself. `bun run --filter antgrid-relay test`. The tests need no
  `.env`; the required-env checks only bite when you actually boot a server.
- **`bridge/` in full** — PTY and terminal lifecycle, file watching, file
  search, port scanning, the protocol schema union, the agent registry,
  work-status folding, tunnel and preview compression, the host server and
  stream mux. `bun run --filter antgrid-bridge test`.
- **`app/` in full** — every Flutter screen, the design system under
  `app/lib/design/`, the Riverpod providers, the connection supervisor, the
  per-project services. `flutter test` and `flutter analyze` need only the
  Flutter SDK, no platform toolchain. This is the largest credential-free
  surface in the repo and the one CI already gates.
- **`packages/antgrid_relay_client`** — the pure-Dart relay and crypto client
  including the handshake implementation and its test vectors. Dart SDK only.
  Same for `packages/antgrid_eval_client`.
- **`evals/`** — the whole end-to-end suite, minus the real-CLI chat tests,
  which skip themselves.
- Docs, CI configuration, the font-token lint, and `npm run typecheck`.

**Needs a local Postgres, but still no third-party account:** `web/` — accounts,
subscriptions, device registration, JWT minting, sign-in — and its tests. Also
`npm run setup`, `npm run dev` and `npm run aspire`, all of which run
migrations. A `postgres:16-alpine` container is enough.

**Genuinely cannot be done credential-free:**

- GitHub and Google OAuth sign-in — needs your own OAuth apps. (Magic-link
  sign-in works without any, so this is not a blocker for full-stack work.)
- Real email delivery — needs a ZeptoMail token.
- Billing — needs Paddle and/or Razorpay keys plus webhook secrets. Two dev
  escape hatches exist, above.
- Geo/country detection (an IPinfo token) and encrypted push (a Firebase
  service-account triple for FCM, an Apple key quartet for APNs). Push is
  genuinely optional — the relay answers `unconfigured` and live in-band
  notifications keep working.
- Driving a real coding agent end to end — needs `claude`, `codex` or
  `opencode` installed *and* logged in, each with its own subscription. The
  bridge's own logic is fully testable without them.
- Release and signing paths: Apple signing, Microsoft Store publishing, Google
  Play, and a Sentry DSN. None are needed for local development; the crash
  reporter's DSN is empty by default, so crash reporting is inert in any local
  build.

---

## Repository layout

| Path | What it is |
|---|---|
| `bridge/` | TypeScript/Bun. Runs on your machine: agent terminals (PTY), file watching, git, port scanning, HTTP tunnelling. Ships inside the desktop app. |
| `relay/` | TypeScript/Bun. Zero-knowledge WebSocket router — authenticates devices, forwards encrypted frames, reads no payloads. |
| `app/` | Flutter/Dart + Riverpod. Desktop and mobile UI: terminal viewer, file explorer, git review, browser preview. |
| `web/` | TypeScript/Bun + Hono + Postgres. Accounts and sign-in, subscriptions, device registration, Ed25519 JWT minting for the relay's gate. |
| `packages/antgrid-wire` | TypeScript. Frame codec, relay control-envelope schemas, `FRAME_VERSION`, shared client-IP resolver. Consumed by bridge, relay, web and evals. |
| `packages/antgrid_relay_client` | Pure Dart relay and crypto client, no Flutter. The app's transport layer. |
| `packages/antgrid_eval_client` | Dart end-to-end test fixtures. |
| `site/` | Astro. The static marketing site at `antgrid.ai`. Its own Bun project, **not** a root workspace — `bun install` from the root does not cover it. |
| `evals/` | End-to-end suite: real bridge processes, an in-process relay, real PTYs. |
| `aspire/` | The Aspire orchestrator used by `npm run aspire`. |
| `scripts/` | Setup, the fallback dev runner, the Android PTY build, and other one-off tooling. |
| `docs/` | Design notes, protocol specs and release procedures. |

Message flow, the shared-package breakdown and the `antgrid.yaml` project schema
are in [`docs/architecture.md`](docs/architecture.md). The end-to-end handshake
has its own specification at
[`docs/protocol/e2e-handshake.md`](docs/protocol/e2e-handshake.md).

Note that the wire protocol is mirrored **by hand** between TypeScript and Dart
— `packages/antgrid-wire` and `packages/antgrid_relay_client` do not share code.
A change on one side that is not made on the other fails silently at runtime,
not at compile time.

---

## Troubleshooting

**`Cannot find module '../generated/prisma/client.js'`**
The Prisma client has not been generated. Run `bun install` from the repo root;
the root `postinstall` generates it. After a schema change, run
`bun run --filter antgrid-web prisma:generate`.

**`Migration failed. Is Postgres running and PG_DATABASE_URL correct?`**
Exactly what it says. Check that Postgres is up and that `PG_DATABASE_URL` in
`web/.env` points at it. Setup prints the value it tried.

**Web tests fail with `PG_DATABASE_URL not set`, or with a permission error on
`CREATE DATABASE`**
The test harness builds a template database and clones it per file. Set
`PG_DATABASE_URL`, and connect as a role with **CREATEDB**.

**`LNK1104: cannot open file 'jvm.lib'` on Windows**
No JDK. Install one (`winget install Microsoft.OpenJDK.21`), then read
[Trap 1](#trap-1-a-failed-windows-cmake-configure-poisons-appbuild-permanently)
— you almost certainly also need to delete `app/build/windows`.

**Windows build compiles cleanly, then fails INSTALL with
`cannot create directory … Maybe need administrative privileges`**
Not a permissions problem. See
[Trap 1](#trap-1-a-failed-windows-cmake-configure-poisons-appbuild-permanently).

**`flutter analyze` hangs forever with no output**
Something else is holding the analyzer's startup lock — another `flutter
analyze`, a `dart analyze`, or your editor. See
[Trap 2](#trap-2-never-run-flutter-analyze-or-dart-analyze-concurrently).

**`flutter.sdk not set in local.properties`**
Gradle ran before Flutter generated `app/android/local.properties`. Run
`flutter pub get` in `app/` first.

**Flutter errors "no devices" under `npm run aspire:android` / `:ios`**
The emulator or simulator must be booted before `aspire run`. Boot it, then
start Aspire.

**The app runs but you cannot sign in, and the logs look fine**
The build is talking to staging. If you started the app yourself, pass both
dart-defines. See
[Trap 5](#trap-5-a-debug-app-build-talks-to-staging-not-your-local-stack).

**The app connects to web but never to the relay**
Port mismatch between the launcher and `RELAY_URL`. See
[Trap 6](#trap-6-the-relay-listens-on-a-different-port-under-each-launcher).

**Sign-in email never arrives**
Expected — `ZEPTOMAIL_TOKEN` is unset by default and the sender degrades to a
console logger. The magic link is printed to the web server's stdout, prefixed
`[email:dev]`.

**The GitHub or Google sign-in button fails immediately**
Also expected. Setup fills those four client-id/secret variables with literal
stubs because the schema requires them to be non-empty. Use the magic link, or
supply your own OAuth apps.

**`bun install` won't take the dependency version you asked for**
Versions published in the last 14 days are refused by policy. See
[Trap 7](#trap-7-bun-install-refuses-brand-new-package-versions).

**`npm run check:font-tokens` fails on Windows with a shell error**
It is a bash script. Run it from Git Bash or WSL.

**A test run at the repo root is slow and flaky**
You ran a bare `bun test`. See
[Trap 3](#trap-3-never-run-a-bare-bun-test-from-the-repo-root).

**`git status` shows `.mcp.json` modified after `npm run setup`**
Expected. Setup registers a local Dart tooling entry there and the file is
tracked. The edit is additive; keeping or reverting it are both fine.

---

## Licence

Antgrid is source-available under the [Elastic License 2.0](LICENSE.md). It is
not an OSI-approved open-source licence. You may read, modify, self-host and fork
it; you may not offer it to third parties as a hosted service or circumvent the
licence-key functionality.

`packages/antgrid-wire` and `packages/antgrid_relay_client` are Apache-2.0
instead, so anyone can build an Antgrid client and audit the cryptography. Each
carries its own `LICENSE` and `NOTICE`, and [LICENSING.md](LICENSING.md) maps
every path to its licence. Apache code may be used inside an ELv2 component;
never move code the other way.

External pull requests are not being accepted yet — ELv2's grant is
non-sublicensable, so taking patches needs a contributor licence agreement that
does not exist yet. [CONTRIBUTING.md](CONTRIBUTING.md) explains the position.
Nothing about forking or self-hosting is affected.
