# CLAUDE.md

This file provides guidance to Coding Agents (like Claude, Codex, etc) when working with code in this repository.

> Pre-release. Working towards v1.
> Do not create dev worktrees (`npm run worktree`) unless asked — this is about
> your own scratch checkouts, not the isolated-session worktrees the product
> manages for users.

> **Maintaining this file.** Update it in the same commit that invalidates a fact. Before writing any fact, ask *will this be wrong after 3 months of normal work?* — if yes, pin a pointer to its source of truth (a command like `flutter test`, a directory, or a symbol + file) instead of the value. Never pin counts, exhaustive lists, file-tree dumps, or line numbers; keep only load-bearing invariants. If a command already reports a number, delete the number.

## Project Overview

Antgrid is a modern agent-first IDE, focused as coding agent (Claude Code, Codex, etc.) command centre with remote control. Remote control is fully E2E-encrypted platform for monitoring and controlling AI coding agents from mobile/desktop. All agent↔app traffic is end-to-end encrypted (X25519 ECDH + AES-256-GCM); the relay is zero-knowledge and only sees opaque blobs.

The app should feel agent command centre, not a web dashboard. It prioritizes information density, fast scanning, and keyboard/gesture efficiency. The agent's terminal output is the primary view; files, git, and preview are supporting context.

| Component | Path | Stack | Role |
|---|---|---|---|
| **Bridge** | `bridge/` | TypeScript/Bun | Runs on dev machine: terminals (PTY), file watching, port scanning, HTTP tunneling. Entry: `src/index.ts`. |
| **Relay** | `relay/` | TypeScript/Bun | Zero-knowledge WebSocket router. Never reads payloads. Entry: `src/index.ts`. |
| **App** | `app/` | Flutter/Dart + Riverpod | Mobile/desktop UI: terminal viewer, file explorer, browser preview. |
| **Web** | `web/` | TS/Bun + Hono + Postgres | Licensing, subscriptions, OAuth device-flow, Ed25519 JWT minting, Better-Auth sign-in. Entry: `src/index.ts`. |

Shared packages in `packages/`: **`antgrid_relay_client`** (pure Dart relay/crypto client, no Flutter), **`antgrid_eval_client`** (E2E eval fixtures), **`antgrid-wire`** (TS: route-frame codec + relay control-envelope Zod schemas, shared by bridge/relay/web/evals; source of truth for `FRAME_VERSION`, and the Dart client mirrors it **by hand**). Full breakdown, the message flow and the `antgrid.yaml` schema: `docs/architecture.md`.

## Gotchas (read before editing)

- **Environment is Windows + PowerShell.** Prefer the Bash tool for documented commands; in PS 5.1 `&&` fails (use `;`), paths are backslashed.
- **Git commits via the Bash tool: use `-m` flags (repeat per paragraph), never PowerShell `@'...'@` here-strings** — the Bash tool is bash, so `@'...'@` leaves a stray `@` in the subject (has shipped to remote more than once).
- **Bun workspace filter names ≠ directory names**: `antgrid-bridge`/`-relay`/`-web`/`-wire`/`-evals`, not `bridge`/`relay`/etc. `bridge/plugin` breaks even that pattern — it is `@antgrid/plugin`. One root `bun install` covers every workspace — but **not** `site/` or `aspire/`, which are separate Bun projects with their own lockfiles and need their own install.
- **NEVER run `flutter analyze` (or `dart analyze`) concurrently — it deadlocks silently.** `flutter/bin/internal/shared.bat` takes a startup lock in a sleepless `GOTO` retry loop with stderr sent to `NUL`, so the second invocation spins forever emitting nothing and never times out; `dart.bat` calls the same script. Two agents analyzing at once is enough. Use the MCP `analyze_files` while iterating (see Test, typecheck, lint).
- **No Material visual artifacts in the app.** Use the Antgrid design system (`app/lib/design/`) exclusively — see Design Rules.
- **`copyWith`: never combine `clearX: true` with an explicit value for the same field.** It's ambiguous and bug-prone.
- **Run tests via `bun run test` / `npm run test` (per-workspace), NEVER bare `bun test` from repo root** — root recurses stale worktree copies + the E2E `evals/` (real agents/relays/PTYs) into one port space → flaky, minutes-long runs. Evals run explicitly: `bun run --filter antgrid-evals test:evals`.
- **web tests need Postgres** (`PG_DATABASE_URL`) + the generated Prisma 6 client (`src/generated/prisma/`, regen `bun run --filter antgrid-web prisma:generate` after schema changes — `bun run migrate` only applies migrations). `pretest` regenerates client + Vite assets; tests clone one migrated template DB (`tests/helpers/preload.ts`).
- **Android floors**: Gradle 8.14 + AGP 8.11.1 (transitive AndroidX hard-requires AGP ≥ 8.9.1). Keep explicit KGP 2.2.20 — built-in Kotlin migration downgrades to Gradle's embedded 2.0.0, below Flutter's floor. `flutter_local_notifications` needs core library desugaring (`app/android/app/build.gradle.kts`).
- **Android 16 KB page alignment** (Play gate): every bundled 64-bit lib must have LOAD `p_align` ≥ `0x4000`; the aligned `portable_pty` library ships inside the Antgrid fork's prebuilt, so nothing re-applies alignment on dev machines or in CI. **Alignment comes from the `max-page-size`/`common-page-size` linker flags, not the NDK version** — measured on `aarch64-linux-android`, r27c emits `0x1000` without them and `0x4000` with them, so a regression is never fixed by bumping the NDK; fix it where the artifact is linked (`docs/dart-terminal-fork-release.md`). Verify with `llvm-readelf -l <lib>`; the nightly `deploy-android` always gates the release AAB on it, and `ci-android` does whenever the diff touches the native surface (otherwise it builds a single-ABI APK and skips the check — nothing in such a diff can move a lib's alignment). Keep `jniLibs { useLegacyPackaging = false }` — that is zip alignment in the APK, a separate concern from per-lib ELF `p_align`. Upstream: kingwill101/dart_terminal#17.
- **`flutter_launcher_icons` corrupts `app/ios/Runner.xcodeproj/project.pbxproj` on every run** — it writes `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = AppIcon` into the Runner target's Release and Profile configs. The setting is a boolean; it is confusing it with `ASSETCATALOG_COMPILER_APPICON_NAME`. Reset the two lines to `YES` after `npm run gen:icons` — the wrong value has already been committed once, and neither `flutter analyze` nor `flutter test` sees it.
- **Windows build needs VS 2022+/18 with the C++ workload AND a JDK.** VS 2019's CMake 3.20 fails; VS 18 2026 with its bundled CMake 4.3.1 is measured green. The tree asks only 3.14 (`app/windows/CMakeLists.txt`), so the real floor is whatever the Windows plugins demand. The JDK is not optional: `sentry_flutter` pulls `jni`, which declares Windows support, so every configure runs `find_package(JNI)` and the link dies `LNK1104 ... jvm.lib` without one. Any full JDK works (`winget install Microsoft.OpenJDK.21` sets `JAVA_HOME` itself).
- **A failed Windows CMake configure poisons `app/build/` permanently.** The install-prefix block in `app/windows/CMakeLists.txt` sits *after* `include(flutter/generated_plugins.cmake)`, and `CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT` is true only on the FIRST configure — so one plugin error (a missing JDK will do it) leaves the prefix at `C:/Program Files/antgrid` and no later successful configure ever corrects it. Symptom is a clean compile that dies in INSTALL with "cannot create directory … Maybe need administrative privileges", which reads like a permissions problem and is not. Fix the plugin error, then delete `app/build/windows` — re-running the build alone cannot recover.
- **Windows ships only as a Store MSIX, and a packaged binary is launchable from OUTSIDE the package only if `AppxManifest.xml` declares it as an `<Application>`.** An undeclared one fails `CreateProcess` with `ERROR_ACCESS_DENIED` — surfaced by libuv as `EPERM: uv_spawn` — even though its DACL grants execute; only the app itself, which holds package identity, can spawn a sibling. Every agent's hook config names `antgrid-bridge.exe` by absolute path (`resolveHookCommand` bakes `process.execPath`), so losing that declaration kills every hook for every agent, silently and in the field. `scripts/patch-msix-manifest.ps1` adds it between `msix:build` and `msix:pack` — the `msix` package emits exactly one `<Application>` and its `execution_alias` only ever aliases the main exe — and `scripts/verify-msix-executables.ps1` gates the packed artifact. Two non-obvious parts of that declaration: an `<Application>` is **single-instance by default**, so the bridge needs `desktop4:SupportsMultipleInstances="true"` or concurrent hooks collapse into one process; and `Subsystem="console"` exists only on `uap5:AppExecutionAlias`, so the older `uap3` + `desktop:ExecutionAlias` spelling cannot carry it. `bridge/scripts/smoke-hook-binary.ts` cannot cover any of this: it runs the loose binary, which is the case that always works. **The helper must stay visible in the app list** — one `AppListEntry="none"` anywhere makes the whole package a headless app, which Store ingestion refuses without Microsoft's per-product `HeadlessAppBypass` waiver (request: storeops@microsoft.com). It fails at submission commit, minutes after a full upload, so pack and `verify-msix-executables.ps1` both pass first.
- **A Store update while the bridge host is alive permanently bricks the package.** Every child of the app inherits its Desktop AppX **silo** (measured on 26200 — children do NOT break away), so `antgrid-bridge.exe` and its whole PTY tree are silo members. The update force-kills the app, which fires neither `didRequestAppExit` nor `HostTeardownObserver`; `owner-watchdog.ts` notices ~2s later and then drains *gracefully* for up to 5s more, so members are still live while the Store destages. A silo destroyed with members leaks the package's Helium hives (`%LOCALAPPDATA%\Packages\<family>\SystemAppData\Helium\{User,UserClasses}.dat`) mounted with no owner; the next launch cannot convert a fresh job into that family's silo, fails `ERROR_SHARING_VIOLATION` (0x80070020 → AppXDeploymentServer events 215 + 208), and the shell reports "Another program is currently using this file". **Only sign-out or reboot clears it** — `Reset-AppxPackage`, `Add-AppxPackage -Register`, and service restarts all fail, and Windows' own `RepairAppRegistrationOption` retry is what fails on every launch. The hard backstop is `app/lib/launcher/windows_job_object.dart`: the app assigns each spawned host to a job with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and never closes the handle, so the kernel sweeps the tree as it reaps the app — on force-kill too, which is the only path that matters. A nested job inside a silo IS permitted and DOES sweep grandchildren (measured). Keep the assignment BEFORE the stdin bootstrap write in `spawnHostProcess`: the host blocks on `readBootstrapPayload()` as its first act, which is the only thing making the window race-free — and it only holds while the spawned pid IS the bridge, not the `cmd.exe` of a `.cmd` `ANTGRID_AGENT_BIN`. POSIX has no equivalent that survives a SIGKILLed parent — the watchdog stays the sole backstop there. `UpdateInstallController` (`app/lib/update/update_install_controller.dart`) drains the host gracefully before handing an update to the Store, but that is an improvement on the sweep, never a replacement — the job object stays the only thing standing between a mistake here and a bricked package. The app remains fully interactive for the Store's whole window (two consent dialogs, download, deploy), so the drain alone would be undone by the first `ensureHost()`; `HostController.sealSpawns()` is what makes it hold, and every path that does NOT hand the process over owes an `unsealSpawns()` — a seal nothing lifts leaves the machine unable to start any agent.
- **Relay Bun floor**: the relay requires Bun ≥ 1.3.14 for iOS direct-APNs push — Bun 1.3.10 fails the APNs sandbox TLS/ALPN handshake. Pin CI/runtime to 1.3.14+, not floating `1.3`.
- **Encryption & command-exec boundaries are non-negotiable** — see Conventions.

## Commands

Bun workspace: one root `bun install` covers every workspace listed in the root `package.json`'s `workspaces` array. Workspace scripts run from root via `bun run --filter <name> <script>`; the `cd <subdir>` forms also work (Bun walks up to the workspace root).

`site/` and `aspire/` are **outside** that array — each is its own Bun project with its own lockfile, so a root install leaves them empty. Install in the directory (`aspire/` also needs a one-time `aspire init`; see `npm run aspire`).

### Dev & setup
```bash
npm run setup        # Idempotent: per-service .env (shared RELAY_INTERNAL_SECRET),
                     # prisma migrate deploy, seed dev user + active "pro" sub.
npm run aspire       # DEFAULT launcher: full stack under Aspire dashboard (unified
                     # logs/OTel). One-time: `aspire init` + `npm install` in aspire/.
npm run dev          # Fallback: all services concurrently (scripts/dev.ts)
npm run dev:agent | dev:relay | dev:web | dev:app   # Per-service
cd app && flutter run -d windows        # App directly (or -d macos, -d linux)

# App URL defaults are build-mode aware: debug/profile → *.staging.antgrid.ai,
# release → *.antgrid.ai (see app/lib/config/environment.dart). To point a debug
# build at the LOCAL aspire/dev stack instead of staging, pass both overrides:
cd app && flutter run -d windows \
  --dart-define=RELAY_URL=ws://localhost:3000 \
  --dart-define=LICENSE_API_URL=http://localhost:8787
```

### Everything else — `docs/commands.md`
Worktree provisioning (`npm run worktree`, never raw `git worktree add` — it
leaves the checkout missing `node_modules`/`.env`/prisma and untestable), the
read-only probes `npm run wt` and `npm run sym -- <Symbol>` (prefer them over
hand-rolled `git rev-parse`/`merge-base`/per-file `git grep`), the bridge CLI
and phone management, `dev-grant`, and the web migrate/keygen commands.

### Test, typecheck, lint
The full gate set, per workspace (never bare `bun test` from root — see Gotchas):
```bash
bun run --filter antgrid-bridge test     # also: antgrid-relay, antgrid-web
bun run --filter antgrid-evals test:evals   # E2E; explicit only, never in a sweep
cd app && flutter test
cd packages/antgrid_relay_client && dart test
npm run check:font-tokens                # Fails on raw `fontSize:` literals in app/lib (see Design Rules)
```
**Dart analysis — MCP tool while iterating, CLI to gate.** The Dart MCP server
(`.mcp.json`) keeps ONE warm analysis server, so `analyze_files` is ~instant on
repeat calls and many agents can share it. `flutter analyze` boots a fresh ~1GB
server per run and cannot be run concurrently (see the startup-lock gotcha) —
run it once, from the controller, as the CI-equivalent gate. Same split as the
test-gating rule: implementers iterate, the controller gates. `analyze_files`
reports ERRORS ONLY, so its "No errors" does not mean the gate is clean —
warnings and infos (`unnecessary_cast`, `use_null_aware_elements`, …) surface only
in the CLI run. Never take an agent's `analyze_files` result as the gate.

## Conventions (MUST / NEVER)

- **Zod everywhere** — all message types and config schemas use Zod v4 for runtime validation.
- **Adding a message type** requires ALL of: schema in `protocol.ts` → add to `AbMessageSchema` union → add to `KNOWN_TYPES` set → export the type → handle the `case` in `handleAbMessage` (`bridge/src/agent-core.ts` — the inbound switch; `index.ts` is only the commander CLI and routes no message types). Miss one and it silently fails. If the type reads or writes the working tree, it also belongs in `CHECKOUT_VARIABLE_MESSAGE_TYPES` — see below.
- **Checkout-scoped routing** — an isolated session runs in a managed git worktree, so anything filesystem-variable (files, tree, search, Git, commands, preview, terminals, the handler's judge cwd and destructive-path floor) must resolve from the session's checkout, never from the project path. `CHECKOUT_VARIABLE_MESSAGE_TYPES` (`bridge/src/protocol.ts`) is the authoritative set and is mirrored BY HAND as `kCheckoutVariableMessageTypes` (`app/lib/project/project_message_classification.dart`); the two drifting apart is silent. An app that doesn't advertise the `checkoutRouting` capability is refused a project holding a managed session rather than shown main's workspace beside an isolated agent. `WORKTREE_SESSIONS_SUPPORTED` (`bridge/src/worktree-capability.ts`) is the kill switch. Inbound `session:*` verbs are deliberately NOT in that set — they name a `sessionId` and the bridge resolves the checkout from the entry, so a `checkoutId` on such a frame is a second, conflicting answer to a question already settled host-side (`session:result` is in the set because it carries the checkout back OUT). `bridge/tests/checkout-protocol-contract.test.ts` pins it, `session:setup` included.
- **Command execution is gated by account membership AND one machine-level remote-access switch, not by origin.** A phone is trusted the moment the bridge resolves its identity from the signed-in user's account inventory (no pairing ceremony); trust alone is NOT enough. A remote phone may drive project X iff it is account-trusted **AND** the machine's remote-access boolean is on (`remote-access-policy.ts`, the sole authorization store — `paired-phones.ts` is identity/push/last-seen only) **AND** X is in the host's project catalog (`seenProjects` in `host-server.ts`). Default is off on a fresh install; off is machine-wide and immediate. That catalog lookup plus `isSafeProjectId` are the *only* thing bounding which projectId a phone may name — nothing backs them up, so never refactor them away as redundant. Loopback/local callers are exempt by design (`currentPhoneAllowed()` in `agent-core.ts`): the desktop drives its own machine with the switch off. The `antgrid phones remove` CLI is **not** a revocation — see `docs/commands.md`.
- **NEVER make encryption optional.** All agent↔app messages are encrypted after handshake; the relay never holds decryption keys.
- **The repo is dual-licensed and the boundary is one-way.** `packages/antgrid-wire` and `packages/antgrid_relay_client` are Apache-2.0 and carry their own `LICENSE`; everything else Antgrid owns is ELv2 (`LICENSING.md` is the map). Apache code may be used inside an ELv2 component — **never move a file the other way**. Hoisting a shared helper out of `bridge/`, `relay/`, `web/` or `app/` into either package relicenses it permissively, and once published that cannot be undone. It compiles, CI stays green, and nothing warns you.
- **Platform-aware code** — port scanning, shell detection, clipboard all branch per OS (Linux/macOS/Windows). Keep all three branches working.
- **Eval harness** — E2E tests use `setupTestEnv()` (starts in-process relay with a fake license gate, spawns a real agent, connects `RelayClient` as an account-trusted app — no pairing frame, no QR); `createTestProject()` makes temp projects with antgrid.yaml + sample files. Project verbs run on the firstProject STREAM (`openProjectStream`/`sendOnStream`, helpers in `evals/support/`), not the control plane, and state comes from `pullStateSnapshot()` — v3 dedups welcome-replayed adverts, so never await a live `agent:projects` push. The v3 merge-gate suites live at `evals/tests/gate-*.test.ts`; `test:evals` runs `scenarios/` + `tests/`.

## Design Rules (app UI)

Full rules live in `app/CLAUDE.md`, which auto-loads whenever you work under
`app/` — all Flutter UI is there. The two that must never be violated, restated
here because they are easy to break from outside that tree:

- **NEVER use raw Material widgets, `Icons.*`, or inline color/spacing literals.** Use `app/lib/design/` — `AbIcons.*`, `AbTokens`, and the existing `AbX` widgets.
- **Sans for chrome, mono for code/data.** Not machine-checked — `npm run check:font-tokens` only bans raw `fontSize:` literals, so the family rule is on you.

## Code Comments

Comments are permanent docs for the next reader, not a log of this chat — write them as if the conversation that produced them never happened.

**Comment WHY, never WHAT.** Code already shows what it does; a comment earns its place only by explaining intent, a non-obvious constraint, a tradeoff, or a gotcha invisible in the code.
- ✅ `// Bare deviceUuid, not registrationId — pairing is machine-level (see paired-phones.ts)`
- ❌ `// loop over phones and check if allowed`

**Never:** conversational or instructional residue ("rebuild now", "as discussed", "per your request"); change narration ("was 5, now 10" — that's git's job); restating the line below; commented-out code (delete it, git remembers).

**Sparingly:** the reason behind a non-obvious choice or an external-bug workaround (link the source); invariants a future edit could silently break ("keep in lockstep with web's jwt-bearer.ts"); `TODO(owner): <actionable>` for durable follow-ups only — never a note to the current reviewer.

**Default to no comment.** If the code needs prose to be understood, first reach for a clearer name or a smaller function.

---

## Architecture (deep reference)

`docs/architecture.md` — message flow, the shared-package breakdown, and the
`antgrid.yaml` schema.

### Per-component deep reference
Each file below loads only when you work under its directory — read it before
editing that component; the repo-wide rules stay in this file.
- `bridge/CLAUDE.md` — PTY/terminals, relay-client v3 auth, stream mux, host server, OAuth bootstrap, isolated checkouts.
- `relay/CLAUDE.md` — hello verification order, epochs, routing, streams, license gate, error contract.
- `app/CLAUDE.md` — providers, ConnectionSupervisor, per-project services/registry, account auth.
- `packages/antgrid_relay_client/CLAUDE.md` — relay service + MachineSession (NOT under `app/`, so it loads separately).
- `web/CLAUDE.md` — Prisma/Better-Auth, device + JWT routes, the two pricing axes.
