# Owning the native artifacts: forking `dart_terminal`

Reference for self-hosting the prebuilt `ghostty-vt` and `portable_pty_rs`
libraries instead of downloading them from `kingwill101/dart_terminal`. The fork
is an infra upgrade, never on the critical path for shipping — the App Store
build is already green via the committed iOS override
(`app/.prebuilt/ios-arm64/libghostty-vt.dylib`), and Play's 16 KB gate is
satisfied by the fork's own aligned PTY release.

Fork: `antgrid-ai/dart_terminal`, cloned at `…/GitHub/dart_terminal`. It moved
there from a personal account, and GitHub redirects the old slug — but only
while nothing reclaims it, and the PTY build hook resolves release artifacts by
slug at hook time, so never create a repo at the old name.

## Status

| | State |
|---|---|
| PTY fork release | **Done.** `portable_pty-v0.0.6+antgrid.2`, 16 KB-aligned Android, dynamic iOS, verified |
| VTE fork release | **Not needed** — the native library is byte-identical to upstream's |
| `terminal_view.dart` port | **Done.** Pushed as `e6a1fea`; the three orphaned suites followed in `ef2a31d` |
| Antgrid cutover | **Done.** Git overrides pinned, vendored packages and the Android workaround gone, iOS dylib regenerated; TestFlight upload green |

Everything the fork side owed has shipped. The checklist below is the live record
of the cutover. What is left is verification, not work: the v0.1.4 iOS dylib has
never run on a physical device, and Linux has never been built against the fork.
One open decision on vte `ios-arm64` only binds
when iOS submission is imminent. Facts below marked *measured* were
established by running the thing, not by reading either tree — the sections they
sit in say how.

## What actually diverges

Antgrid does not merely re-host binaries. Divergence runs on three axes, and
each one has a different remedy:

| Axis | Where | Remedy |
|---|---|---|
| Dart source | `packages/ghostty_vte`, `packages/ghostty_vte_flutter` | Publish or git-dep the fork; no binary release needed |
| Rust source | `packages/portable_pty/rust` | Needs a fork *release* — the binary is what ships |
| Native binaries | the two platform exceptions below | Needs a fork release |

`ghostty_vte_flutter` is the largest divergence by far, and it ships **no native
code** — so none of it depends on a release. It only needs a pushed commit.

*Measured* by diffing the fork's `lib/src/` against Antgrid's vendored copy
(ignoring trailing whitespace, since the vendored files are CRLF):
**the fork is now a strict superset of every vendored file.**
`terminal_render_model.dart` is +102/−2 in the fork's favour, the palette and
contrast helpers differ only in `dart format` wrapping and doc-comment wording,
and `terminal_view.dart` — the last holdout — is +351/−10 since `e6a1fea`. Each
of those ten lines was checked: two `if` guards `dart format` rejoined onto one
line, two doc comments that had to change because the fork restores the formatter
render path for web, and one debug label (`'renderState (no data)'` →
`'renderState (fmt fallback)'`) tracking that same behaviour. No lost patch.

The one apparent exception is worth recording, because it looks like a dropped
patch and is not. Antgrid's `terminal_controller_native.dart` calls
`_flushFocusReport()` from `appendOutputBytes`; the fork's does not. The fork
moved that call **into `_ingestBytes`**, so the latched DEC-1004 focus state is
re-asserted on *every* ingest path — PTY, external transport, and injected debug
output — rather than one of them. Strictly better. Before concluding a patch was
lost, check whether it moved.

## The `portable_pty` SIGCHLD patch is superseded — do not port it

Antgrid's `packages/portable_pty/rust/src/lib.rs` wraps `ensure_sigchld_handler`
in a `HANDLER_MUTEX`. That patch was written against v0.0.5, which installed the
handler and captured the previous one in a **single** `sigaction` call writing
straight into a static: two concurrent spawns could both pass the "is it still
ours?" check, and the second call then recorded the first's just-installed
handler as the previous action, self-chaining into infinite recursion on the next
SIGCHLD.

Upstream v0.0.6 restructured the same function: it queries the current action
with a separate read-only `sigaction`, publishes an immutable
`PreviousSigchldAction` behind an `AtomicPtr` **before** installing, and passes
`null` for `oldact`. A thread that reads our own handler returns early and can
never record it, so the self-chain is unreachable; and the signal handler can no
longer observe a torn action mid-reinstall. This is strictly stronger than the
mutex, which fixed the recursion but left the handler's read of
`PREV_SIGCHLD_ACTION` racy.

**Consequence for the fork plan.** "Ship our Rust fix" is no longer a reason to
cut a release. The mutex only ever reached the two Android ABIs Antgrid compiled
itself from the vendored tree; every desktop platform has always run upstream's
downloaded binary, so the patch never reached macOS/Linux/Windows at all. Adopting v0.0.6's published prebuilts is what fixes desktop, and that
requires no fork release.

## Where the binary comes from now: `native_prebuilt`

Upstream v0.1.4 / v0.0.6 replaced the hand-written hook with an external package.
Both `hook/build.dart` files collapsed to a five-line delegation:

```dart
import 'package:native_prebuilt/hooks.dart';
Future<void> main(List<String> args) => nativePrebuiltBuild(args);
```

`native_prebuilt: ^0.3.2` is a pub.dev dependency, not vendored. All download,
verification, and fallback logic lives outside the repo, so none of it can be
read from either tree. Everything below was read out of the resolved package in
the pub cache and confirmed by running a build.

Configuration moved to two per-package files:

| File | Authored by | Consumed by |
|---|---|---|
| `native_prebuilt.yaml` | hand — source of truth | the hook, and `native_prebuilt manifest update` |
| `native_prebuilt.lock.yaml` | generated in CI | the hook (integrity check) |

The lock records **two** digests per platform: `archive_sha256` (the `.tar.gz`)
and `payload_sha256` (the library inside it).

### The resolver chain — three stages, and the env vars are gone

*Measured* against `native_prebuilt` 0.3.2 (`src/builder/native_project_builder.dart`,
`src/resolution/prebuilt_resolver.dart`), and observed end-to-end in a build log.
Stages run in order; the first non-null result wins, and a source build is
attempted only if all three come back empty.

| # | Resolver | Reads |
|---|---|---|
| 1 | `UserDefinePrebuiltResolver` | `hooks: user_defines: <pkg>: prebuilt_path:` in pubspec.yaml |
| 2 | `LocalPrebuiltResolver` | `.prebuilt/<target.label>/<canonicalName>` |
| 3 | `SharedCacheResolver` | downloads the release asset, verifies against the lock |

**Stage 2 is what keeps both Antgrid platform exceptions alive**, and it is
unconditional — it runs ahead of the download for every target. Three details
decide whether an override is actually seen:

- **The filename must equal `canonicalLibraryName`** — `libghostty-vt.dylib`,
  `libportable_pty_rs.so`, `portable_pty_rs.dll`. Both committed overrides match.
- **Search roots are every ancestor of the hook's output directory holding BOTH
  `pubspec.yaml` and `.dart_tool`, plus the package root.** `app/` qualifies, so
  `app/.prebuilt/` is found. The repo root has no `pubspec.yaml`, so the
  "monorepo `.prebuilt/`" that upstream's README documents does not exist in
  0.3.2. Nothing in Antgrid relies on it.
- **Stage 2 performs no integrity check.** It hashes the file to report a
  provenance string, never to compare against `payload_sha256`. A local override
  therefore beats a *corrected* download silently and forever — which is exactly
  why the Android phase of the cutover deletes `app/.prebuilt/android-*/` before
  verifying, rather than leaving it as a harmless belt-and-braces.

**There is no environment-variable stage at all.** The package reads no
environment variable anywhere in resolution (its one `Platform.environment` use
passes the ambient env to spawned build commands). Every env var the vendored
hand-written hooks honour — `GHOSTTY_VTE_PREBUILT`, `PORTABLE_PTY_PREBUILT`,
`GHOSTTY_VTE_PREFER_SOURCE`, `GHOSTTY_SRC`, `GHOSTTY_SRC_URL`, `GHOSTTY_SRC_REF`,
`GHOSTTY_SRC_AUTO_FETCH` — becomes inert the moment Antgrid moves onto the fork's
hook. `hooks: user_defines` is the replacement for the first two; the rest have
none. [ios-ghostty-vt-appstore-rejection.md](ios-ghostty-vt-appstore-rejection.md)
documents two of them, and carries a dated-record banner saying so.

### Two hash systems now coexist

`lib/src/hook/asset_hashes.dart` still exists, still carries `releaseTag`
(`ghostty_vte-v0.1.4` / `portable_pty-v0.0.6+antgrid.2`) plus twelve payload
SHA256s, and is still generated by `tool/write_asset_hashes.dart`. It is **no longer on the
build-hook path** — its only consumer is `bin/setup.dart`, which implements the
pre-migration download-and-extract-into-`.prebuilt/<label>/` flow at the project
root. That file is the surviving surface of the old contract. Regenerating one
hash system does not regenerate the other; both CI jobs must run.

Also now dead: `lib/src/hook/source_patches.dart` has zero importers. The
ghostty libc patch is applied inside the recipe by a `patch_libc` step that
`curl`s a `raw.githubusercontent.com` URL pinned to `b3b2115`.
`build_cache.dart`, `dynamic_library.dart`, and `artifacts.dart` survive only as
dependencies of `bin/setup.dart`, `tool/prebuilt.dart`,
`tool/write_asset_hashes.dart`, and tests.

### The source fallback compiles a remote revision

`native_prebuilt.yaml`'s `build.recipes` describe how to build each target from
source — cargo (desktop/iOS) and `cross` (android, linux-arm64) for
portable_pty; `cmake_configure`/`cmake_build` driving Zig for ghostty_vte. But
`source:` is a **git** source, not the local package:

| Package | Source pin (in the fork, current) |
|---|---|
| `portable_pty` | `antgrid-ai/dart_terminal` @ `6faee7d`, subdir `pkgs/pty/portable_pty` |
| `ghostty_vte` | `ghostty-org/ghostty` @ `4d605bf` |

A source build therefore compiles a remote pinned revision, **not the checked-out
tree**. Any local Rust edit is inert on that path. That is why PTY's pin was
moved to the fork at a commit carrying `rust/.cargo/config.toml` — left on
upstream, a source build would silently emit 4 KB-aligned Android libraries even
from a checkout that has the fix in hand. `ghostty_vte`'s pin stays on
`ghostty-org/ghostty`; the fork changed no ghostty source.

**The fallback fires only when all three resolvers come back empty** — no
user-define, no local `.prebuilt/`, and a download that could not be satisfied.
It is not a policy switch and there is no flag that selects it (upstream's
`GHOSTTY_VTE_PREFER_SOURCE` is one of the env vars that stopped existing). In
practice it means a source build is what you get on a target the release does not
carry, or when the network fails — so a fallback that fires unexpectedly is
compiling unreviewed remote code on a machine that expected a download.

## The download contract — shape intact, mechanism changed

Still true, **as the fork stands** (bare paths like `hook/build.dart` below refer
to the fork; Antgrid's vendored copies are always written `packages/…`, and the
two are at different versions — see the note after the table):

| | ghostty_vte | portable_pty |
|---|---|---|
| release provider | GitHub, `kingwill101/dart_terminal` | GitHub, **`antgrid-ai/dart_terminal`** |
| tag | `ghostty_vte-v0.1.4` | **`portable_pty-v0.0.6+antgrid.2`** |
| tarball prefix | `vte-` | `pty-` |
| toolchain | Zig 0.16.0 | Rust 1.92.0 |
| library basename | `ghostty-vt` | `portable_pty_rs` |

**The two hosts differ on purpose and must stay split.** PTY ships from the fork
because its Android libraries are rebuilt 16 KB-aligned — the bytes are not
upstream's. VTE's native library *is* byte-identical to upstream's (the fork
changed only Dart: regenerated ffigen bindings, which ship in the package, not in
the tarball), so re-hosting it would buy nothing and cost a release to maintain.
Per package, the host is named in three places that must agree:
`native_prebuilt.yaml`'s `release.repository`, `bin/setup.dart`'s `_repo`, and
`_repoFor()` in `tool/prebuilt.dart` + `tool/write_asset_hashes.dart`.

**Platform labels (identical set for both, twelve):** `linux-x64`, `linux-arm64`,
`macos-arm64`, `macos-x64`, `windows-x64`, `windows-arm64`, `android-arm64`,
`android-arm`, `android-x64`, `ios-arm64`, `ios-sim-arm64`, `ios-sim-x64`.

**Each tarball contains exactly one library file, and every slot is dynamic** —
`lib<basename>.{so,dylib}` / `<basename>.dll`. portable_pty's three iOS slots
shipped a static `libportable_pty_rs.a` through `portable_pty-v0.0.6+antgrid.1`
and became dylibs in `+antgrid.2`; see open question 1 below for why the static
payload could never work under Flutter.

**Repointing differs per tree, because only the fork migrated.**

*In the fork*, `hook/build.dart` is a five-line delegation to `nativePrebuiltBuild`
and holds no `_repo`. **PTY is repointed and released; VTE is deliberately left on
upstream** (see the split above). The lock and `asset_hashes.dart` regenerate
themselves — `update-lock` and `update-hashes` commit both on a non-prerelease
tag push — so a release needs no manual hash step. `tool/write_asset_hashes.dart`
and `tool/prebuilt.dart` no longer take an `all` selector: two hosts and two tags
cannot share one `--tag`.

*In Antgrid*, none of that applies yet. The vendored packages still carry the
hand-written hook, and `const _repo` is alive at
`packages/ghostty_vte/hook/build.dart:12` and
`packages/portable_pty/hook/build.dart:12` — it is what builds the download URL,
and `app/pubspec.yaml`'s path overrides mean those hooks are what actually run.
`packages/*/lib/src/hook/asset_hashes.dart` still pins `ghostty_vte-v0.1.3` /
`portable_pty-v0.0.5`. So if Antgrid keeps vendoring rather than moving to git
dependencies, repointing at the fork means changing `const _repo` in both
`hook/build.dart` files and regenerating the hashes — the old instruction, still
correct here.

## Two platform exceptions — one fixed in the fork, one open

Everything else is a plain build. These two are what a fork release is actually
for; get them wrong and a store rejects the upload. Exception 2 is fixed and
released in the fork. Exception 1 is now cured **upstream** as of
`ghostty_vte-v0.1.4` except for the `minos` stamp, which is why what remains of
it is a one-field rewrite rather than a rebuild.

### Exception 1 — ghostty on iOS device (App Store)

A Zig-linked iOS dylib can never carry `LC_ENCRYPTION_INFO` (ITMS-90125) because
that load command is an `ld64` artifact and no post-processing tool can inject
it. See [ios-ghostty-vt-appstore-rejection.md](ios-ghostty-vt-appstore-rejection.md).

**Upstream no longer publishes the rejected binary.** Through `ghostty_vte-v0.1.3`
the `ios-arm64` asset was stamped with Mach-O build tool `5` — Zig's own linker —
and carried no `LC_ENCRYPTION_INFO_64`. `ghostty_vte-v0.1.4`'s is stamped `tool LD`
1267.0 with chained fixups, an exports trie, and `LC_ENCRYPTION_INFO_64` present,
i.e. `ld64` did the final link. ITMS-90125/90209/90080 are therefore cured
upstream, and the paragraph above now applies only to *injecting* that load
command, not to the shipped asset.

**Antgrid's fix is not a static archive.** The rejection doc's original
recommendation (emit a `.a`, let Xcode fold it into `Runner`) was abandoned:
Flutter's iOS native-assets driver only accepts `DynamicLoadingBundled`. It also
no longer relinks: `scripts/build-ghostty-ios.sh` downloads the upstream release
asset and restamps one field, `minos`. The result is force-tracked at
`app/.prebuilt/ios-arm64/libghostty-vt.dylib` (the only file under
`app/.prebuilt/` that git keeps) and is found by the hook's local-`.prebuilt`
lookup before any download.

That restamp is the whole remaining exception, and it is not optional: the asset
is stamped `minos 17.0` (Zig's `aarch64-ios` default) while Flutter hardcodes the
wrapping framework's `Info.plist` `MinimumOSVersion` to 13.0
(`targetIOSVersion`, flutter/flutter#145104) regardless of the app's deployment
target — a framework binary that overshoots its own `Info.plist` is ITMS-90208.
So `IOS_MIN` must track that constant. The Xcode ≤ 16 constraint is gone with the
Zig dependency.

In the fork, either get vte's `ios-arm64` job to stamp a low enough `minos`, or
keep shipping the committed override. Keep `ios-sim-*` either way — simulator
builds are never App-Store-validated.

portable_pty needs no equivalent: cargo → `ld64` already yields compliant output.
Its iOS dylib carries `LC_ENCRYPTION_INFO_64`, which is exactly what the
Zig-linked vte dylib cannot, so the same rejection does not apply.

### Exception 2 — portable_pty on Android (16 KB page size, Play) — **FIXED**

Upstream's Android `.so`s are linked with a 4 KB max page size and fail the
16 KB page-size gate ("LOAD segment not aligned"), blocking Play submission.
Tracking upstream: `kingwill101/dart_terminal#17`.

**The fork fixes it at the source, and the fix shipped** in
`portable_pty-v0.0.6+antgrid.1`. Two things about it are worth keeping:

**Alignment comes from linker flags, not the NDK version.** The original plan
here was to bump `nttld/setup-ndk` from r27c to r28+, on the theory that r28 is
the first whose lld defaults `p_align` to 16 KB. *Measured* on
`aarch64-linux-android`, that framing is wrong — r28 merely changes the default:

| build | worst LOAD `p_align` |
|---|---|
| NDK r28 + flags | `0x4000` |
| NDK r27c + flags | `0x4000` |
| NDK r27c, flags off | `0x1000` (reproduces upstream exactly) |

So no NDK bump was needed. The fix is `-Wl,-z,max-page-size=16384` /
`common-page-size=16384` in `pkgs/pty/portable_pty/rust/.cargo/config.toml`,
checked in. **That location is load-bearing**: the Android targets build under
`cross`, which compiles inside its own container with its own bundled NDK, so a
host `ANDROID_NDK_HOME` or a workflow-level `RUSTFLAGS` may never reach the
compiler — but cargo reads the crate's `.cargo/config.toml` inside the container.
One file therefore covers CI, local builds, and the source fallback alike.

**A `readelf` gate fails the job before packaging** (`prebuilt-pty.yml`, Android
targets only), so a toolchain-default change cannot silently regress it. It was
tested both ways: it rejects upstream's artifact and accepts the rebuilt one.

#### What Antgrid shipped before the cutover, measured

`readelf -lW` on `app/build/app/intermediates/flutter/release/jniLibs/`:

| ABI | `libghostty-vt.so` | `libportable_pty_rs.so` |
|---|---|---|
| arm64-v8a | `0x4000` | `0x4000` |
| armeabi-v7a | `0x4000` | **`0x1000`** |

Two facts fall out, neither of which any workflow guarantees:

- **Ghostty's Android libraries genuinely are 16 KB aligned**, on both ABIs. No
  VTE workflow sets an alignment flag, so this rests entirely on Zig's default
  and nothing verifies it — but it holds today, and VTE needs no alignment work.
- **armeabi-v7a's PTY library was 4 KB aligned**, because the local rebuild
  covered `arm64,x64` only and unlisted ABIs fell through to the 4 KB upstream
  prebuilt. There is no `abiFilters` in `app/android/app/build.gradle.kts`, so
  that ABI does ship. It did not block Play — 16 KB-page devices are 64-bit and
  will not load a 32-bit ABI — and the cutover erases the asymmetry, since the
  crate's `.cargo/config.toml` covers `armv7-linux-androideabi` too. Worth
  recording so it is not rediscovered as a crisis.

That is now history: the local rebuild and its CI mirror are retired, so
alignment is no longer re-applied on every dev machine and CI run — it is a
property of the artifact, and the `readelf` gate in both Android workflows is
what catches a regression.

## The release workflows already exist — fork and adjust

`.github/workflows/prebuilt-pty.yml` and `prebuilt-vte.yml` both trigger on
`workflow_dispatch` and on a push of `portable_pty-v*` / `ghostty_vte-v*`. Each
builds the twelve-label matrix, tars one library per label, then:

| Job | What it does |
|---|---|
| `release` | Unpacks artifacts, runs `dart run native_prebuilt manifest update --config native_prebuilt.yaml --output native_prebuilt.lock.yaml --built-library-dir … --release-assets-dir … --tag $RELEASE_TAG`, publishes via `softprops/action-gh-release` |
| `publish` | Asserts pubspec version == tag suffix, then `dart pub publish --force` for the package **and its `_flutter` sibling** |
| `update-lock` | Commits the regenerated `native_prebuilt.lock.yaml` to `master` |
| `update-hashes` | Runs `tool/write_asset_hashes.dart` and commits `asset_hashes.dart` |

VTE additionally builds a wasm job and builds ghostty from the
`third_party/ghostty` submodule (pinned to `4d605bf`, matching
`native_prebuilt.yaml`'s source revision), applying bundled patches via
`tool/apply_ghostty_vte_source_patches.sh`.

Landmines, all found the hard way while cutting the PTY release:

- **`publish` tries to publish package names the fork does not own.** It runs
  `dart pub publish --force` for `ghostty_vte` / `portable_pty` and their
  `_flutter` siblings — four names owned by kingwill101 on pub.dev — gated only
  on `prerelease != 'true'`, which a normal release cut reaches. **Set to
  `if: false` in both workflows.** Do not re-enable it by aligning versions: the
  "Validate package versions" step aborts today only because `portable_pty`
  carries `+antgrid.1` and `portable_pty_flutter` does not, and that is an
  accident of versioning, not a guard.
- **Never use a `-antgrid.N` release tag.** The release job derives the
  prerelease flag as `VERSION="${TAG##*-v}"; grep -q -- '-'`, so any
  dash-suffixed tag is silently classed a prerelease — which skips `update-lock`
  and `update-hashes` and leaves `native_prebuilt.lock.yaml` and
  `asset_hashes.dart` stale against the release they describe. `+` has no such
  effect and keeps the tag equal to the pubspec version. The *version* cannot
  take a dash either: `0.0.6-antgrid.1` is a semver pre-release and `^0.0.6`
  refuses it, breaking `portable_pty_flutter`.
- **`release.repository` and `source.repository` must both be repointed**, or a
  fork-built release publishes assets to the fork while telling consumers to
  download them from upstream, and the source fallback compiles upstream's crate.
  Done for PTY; VTE stays on upstream by design.

## Consuming the fork from Antgrid

Antgrid's `app/pubspec.yaml` currently points `dependency_overrides` at the
vendored `../packages/*` copies. Replacing those with git dependencies looks like:

Pin `ref` to a commit SHA, not a branch or a tag — the fork cuts no VTE release,
so there is no tag to track, and a branch ref makes every `pub get` a moving
target:

```yaml
dependency_overrides:
  meta: 1.19.0            # required — see below
  ghostty_vte:
    git:
      url: https://github.com/antgrid-ai/dart_terminal.git
      path: pkgs/vte/ghostty_vte
      ref: <sha>
```

*Measured*: the real `app/pubspec.yaml` with its three path overrides swapped for
git overrides resolves cleanly, and a Flutter app built against the fork ships
the native asset. Resolution moves the toolchain forward substantially —
`hooks` 1.0.1 → 2.1.0, `code_assets` 1.0.0 → 1.2.1, `meta` 1.18.0 → 1.19.0, plus
`native_prebuilt` 0.3.2 arriving.

**`resolution: workspace` is not a blocker**, despite every fork package
declaring it and every vendored copy having it stripped. The plausible reading —
that a git dependency fetches the package directory without the workspace root
the key requires — is wrong: `dart pub get` resolves the fork's `portable_pty`,
`resolution: workspace` and all, straight from a git dep. No change is needed on
either side.

**The `meta` override is real and required.** Without it, solving fails outright:

> Because every version of ghostty_vte from git depends on hooks ^2.1.0 which
> depends on meta ^1.19.0 … And because every version of flutter from sdk depends
> on meta 1.18.0 … version solving failed.

Adding `meta: 1.19.0` to `app/pubspec.yaml`'s `dependency_overrides` resolves it.
Note this is **not** a git-dependency quirk — it is the `hooks` 1.x → 2.x jump, so
it applies identically if Antgrid keeps vendoring and re-syncs the copies.

**Flutter's hook runner and the `hooks` package version independently, and that
is the sharpest edge here.** `flutter_tools` 3.47.0 pins `hooks_runner: 1.5.0`
and `hooks: 2.0.2`, while the fork's packages need `hooks ^2.1.0` — the same
major. Under 3.44.8 it was `hooks_runner: 1.1.1` on `hooks: ^1.0.0`, straddling
the 1.x → 2.x boundary.
Pub cannot check this — the runner and the hook are separate processes exchanging
JSON — and nothing in either repository answers it. *Measured* on 3.44.8: a throwaway
Flutter app depending on the fork's `portable_pty` built with
`flutter build windows --release` and shipped `portable_pty_rs.dll`. The
Dart-side runner logged the whole chain (`UserDefine` → `Local` → `SharedCache`),
downloaded from `antgrid-ai/dart_terminal@portable_pty-v0.0.6+antgrid.1`, and
verified the archive hash. **The runner drives a 2.x hook.** Re-check this on any
Flutter SDK bump — it is not a guarantee anyone publishes. *Re-checked on
3.47.0*: `pub get` still solves with no override beyond `meta`, and a debug
Windows build runs both hooks — `ghostty_vte` and `portable_pty` each log a
`native_prebuilt` decision. The release-mode DLL measurement above has not been
re-run against 3.47.0.

**`terminal_view.dart` was the blocker and no longer is.** A git dependency
resolves the *pushed* ref, so an unpushed port silently drops the app's terminal
patches at cutover rather than failing loudly — which is why this was the one
item nothing else could start behind. *Measured* on the fork's committed tree:
`showFocusRing`, `showKeyboardOnInteraction` and
`GhosttyTerminalSoftKeyboardController` — all three used by Antgrid
(`app/lib/widgets/terminal_view_wrapper.dart`,
`app/lib/widgets/terminal_quick_actions_bar.dart`) — are present. Keep that check
falsifiable rather than trusting the commit subject: grep the pushed tree for the
symbols the app imports, not the fork checkout on disk.

The three tests that covered fork code from Antgrid's vendored copy travelled
with `ef2a31d`, fixtures included, so deleting the vendored tree no longer loses
them. (`app/test/terminal_native_color_test.dart` stays put; it imports only
`ghostty_vte_flutter`, as does every other Antgrid consumer — no app code touches
the generated bindings directly.)

## Open questions — settle before trusting the cutover

All four are now settled and documented in the sections above: the local
`.prebuilt/` override survives (stage 2 of the resolver chain, ahead of the
download); the source fallback fires only when all three resolvers come back
empty; and Flutter's `hooks_runner` 1.1.1 does drive a `hooks` 2.x hook. The two
kept below are the ones whose *reasoning* stays load-bearing — re-read them before
touching the iOS link mode or bumping `native_prebuilt` again:

1. **Does `portable_pty`'s iOS link mode still need Antgrid's `artifacts.dart`
   patch?** **Settled — the static payload does not resolve, and it broke the
   first iOS deploy after the cutover** (run 31215469869, `ccbb7e11`):
   `Hook.build hook of package:portable_pty has invalid output — CodeAsset … has
   a link mode "static", which is not allowed by … "dynamic"`, failing the
   archive at `Target dart_build`. Flutter's iOS native-assets driver still
   accepts only `DynamicLoadingBundled`, and `_payloadForRequest` handed it the
   manifest's static payload exactly as predicted.

   The fix is in the fork, not a re-applied Antgrid patch: `+antgrid.2` drops
   `kind: static_library` from the three iOS build recipes and the matching
   `payload: {type: static_library}` artifact blocks, so iOS ships a dylib like
   every other slot. The crate already declares both crate-types, so the same
   cargo invocation yields it. `portablePtyLinkModeForBuild` lost its iOS special
   case too — still off the Flutter path, but it encoded the same wrong claim.

   Reproduced and verified locally on a Mac by simulator build with a cold
   `.dart_tool/hooks_runner`: the pre-fix fork fails with the exact CI error, the
   fixed fork builds and bundles `portable_pty_rs.framework` with an
   `@rpath` install name.

   **The App Store path is confirmed too**, by run 32847826408 — a
   `workflow_dispatch` of `deploy-ios` against the fork at `a4f96a`. It archived
   `ai.radhaai.antgrid` into a 221.1 MB `Runner.xcarchive`, exported an App Store
   IPA and uploaded it to TestFlight. The `has invalid output … link mode
   "static"` failure that broke run 31215469869 does not recur on the real
   signing-and-archive path, so the dynamic payload resolves there and not only
   on the simulator.

   The related simplification does *not* land yet: `deploy-ios.yml`'s
   `aarch64-apple-ios` toolchain step must stay. A dynamic iOS slot falls back to
   compiling the crate whenever the download is unavailable, which is what the
   local verification actually did.

2. **`native_prebuilt` 0.4.0 — settled; the fork is on `^0.4.0` as of `7a76de4`.**
   Every resolution rule recorded in this doc was read from 0.3.2 and **still
   holds by construction, not by re-measurement**: `diff -rq` across the two
   versions' `lib/` reports exactly one changed file,
   `lib/src/binary/binary_inspector.dart`. The resolver chain and the
   local-override precedence both store workarounds rest on are byte-identical.

   What 0.4.0 adds is architecture validation — ELF `e_machine`, Mach-O `cputype`,
   throwing `BinaryArchitectureException` on mismatch. **It does not cover the
   committed iOS override**, which is the one artifact a human places by hand.
   `inspector.inspect()` has exactly two call sites, both in
   `cache/artifact_installer.dart` (the post-extract path and the cached-file
   path), so it guards downloads and the shared cache. The `inspector` field
   lives on `SharedCacheResolver`, which forwards it to `DefaultArtifactInstaller`;
   `LocalPrebuiltResolver` takes only a `directoryName`, and its `resolve()`
   hashes the candidate purely to populate `ResolvedFile.hash` — it validates
   nothing and can reject nothing. `scripts/check-ghostty-ios-abi.sh` is still the
   only gate on that file.

   Note *where* that leaves the validation, because it is close to inverted:
   both call sites run `inspect()` only after the bytes have already matched
   `artifact.payloadSha256`. On the download path the hash pins the exact bytes,
   so the architecture check is a second opinion about a file already known to be
   the intended one. The local override is the one artifact with no manifest hash
   to check against — the only place the check would carry real signal — and it
   is precisely where it never runs.

   A related trap on the cached-file path: `BinaryArchitectureException` and
   `BinaryFormatException` are two independent `final class … implements
   Exception` declarations, with no subtyping between them. The installer's
   self-heal catches `on BinaryFormatException` and deletes the offending cache
   entry, so a malformed file is cleaned up and refetched — but an *architecture*
   mismatch escapes that catch, propagates out of the lock, and leaves the file in
   place, so every later build fails identically until the shared cache is cleared
   by hand. Reaching it requires a payload whose hash matches the manifest while
   being built for the wrong target, i.e. a fork-side packaging mistake — exactly
   the case this validation exists to catch, and the one it handles worst.

   One more sharp edge if a payload ever goes universal, slightly worse than the
   field mix-up alone: `_isMachO` accepts the fat magics
   (`0xCAFEBABE`/`0xCAFEBABF`), but `_validateMachOArchitecture` infers endianness
   by testing only for `0xFEEDFACE`/`0xFEEDFACF`. A fat header is big-endian by
   definition and matches neither, so it takes the little-endian branch and reads
   bytes 4–7 — `nfat_arch` in a fat header, not `cputype` — byte-swapped. A
   two-slice universal dylib therefore reports `cputype` `0x02000000` and is
   rejected as an architecture mismatch. Every slot ships thin today.

## Cutover checklist

### Fork side — done

The release plumbing is repointed (`release.*` and `source.*` for PTY, `_repo`
per package across `bin/setup.dart` + both `tool/` scripts), the `publish` job is
`if: false` in both workflows, the Android alignment is fixed at the source with a
`readelf` gate, and `portable_pty-v0.0.6+antgrid.1` is published and verified
(all twelve assets; `0x4000` on android-arm64; payload sha256 matching both the
committed lock and an independent local rebuild). `+antgrid.2` supersedes it with
dynamic iOS payloads (open question 1).

**No VTE release is needed** — the native library is byte-identical to upstream's
and `ghostty_vte_flutter` ships no native code at all, so the Dart side needed
only a pushed commit. That landed: `e6a1fea` ports `terminal_view.dart` keeping
the formatter render path for web, and `ef2a31d` brings the three
`ghostty_vte_flutter` tests that had lived only in Antgrid's vendored copy.

### Fork side — remaining

1. **Decide vte `ios-arm64`** — either make that matrix job do the clang/ld64
   final link, or drop it from the matrix and keep shipping Antgrid's committed
   override. Not blocking anything until iOS is being shipped.

### Antgrid side — phase 1, desktop — done

2. **Added `meta: 1.19.0`** to `app/pubspec.yaml`'s `dependency_overrides`, and
   swap the three path overrides for git overrides pinned to a SHA (not a branch).
   Delete `packages/ghostty_vte`, `packages/ghostty_vte_flutter`,
   `packages/portable_pty`.
3. **Verified on Windows**: `flutter pub get`, `flutter analyze` (clean),
   `flutter test`, and `flutter build windows --release`, with both
   `portable_pty_rs.dll` and `ghostty-vt.dll` freshly staged into the Release
   bundle by the native-asset hooks rather than left over from a prior build.

   **Verified on macOS** the same way, with `build/macos` and both packages'
   `hooks_runner` caches deleted first so the download path had to run: the hooks
   logged the whole chain (`UserDefine` → `Local` → `SharedCache`) and pulled
   `vte-macos-{arm64,x64}` from `kingwill101@ghostty_vte-v0.1.4` and
   `pty-macos-{arm64,x64}` from `antgrid-ai@portable_pty-v0.0.6+antgrid.2`,
   verifying each against the lock. Both land as universal (x86_64 + arm64)
   frameworks under `Contents/Frameworks/` with `@rpath` install names and a valid
   signature; `ghostty-vt` exports the same 173 symbols as the iOS asset and passes
   `scripts/check-ghostty-ios-abi.sh` (it takes a dylib path, so it is not
   iOS-only). The `GhosttyColorRgb` fix is confirmed *executing*, not just linked —
   `app/test/terminal_native_color_test.dart` passes against the downloaded dylib.

   **Linux remains unverified.** The SIGCHLD non-recursion is unverified
   everywhere and that is fine: SIGCHLD does not exist on Windows, and Antgrid
   never spawns a Dart-side PTY — `TerminalTab` builds its
   `GhosttyTerminalController` with no PTY session and feeds relay bytes through
   `appendOutputBytes`, so `portable_pty` ships only because
   `ghostty_vte_flutter` depends on it. Do not treat that fix as a release gate.

### Antgrid side — phase 2, Android — done

4. **Deleted `app/.prebuilt/android-*/` first.** Stage 2 of the resolver chain
   beats the download and performs no hash check, so leaving those in place would
   have meant the aligned download was never exercised and a regression could not
   be seen.
5. **Confirmed the download is aligned** — `llvm-readelf -lW` on the bundled
   `libportable_pty_rs.so` shows max LOAD `p_align` ≥ `0x4000`.
6. **Retired the workaround**: `scripts/build-pty-android.ts`, its
   `npm run pty:android` entry in `package.json`, the `spawnSync` call in
   `scripts/dev-setup.ts`, and the PTY build step plus its `pty-targets` input in
   `.github/actions/setup-android`. Two things there deliberately stayed: the
   Rust toolchain (`super_clipboard` → `super_native_extensions` compiles Rust in
   the release AAB, and cargokit will not install rustup itself), and the NDK
   step, which is now only the source of the `llvm-readelf` both workflows'
   alignment gate resolves under `$ANDROID_NDK_HOME`.

### Antgrid side — phase 3, iOS (done on a Mac)

7. **Committed iOS dylib rebuilt — settled.** It had been built at ghostty
   `debcffba` (= `ghostty_vte-v0.1.3`) while the fork's bindings are `4d605bf`
   (= v0.1.4), so it exported 102 `ghostty_*` symbols against bindings declaring
   106 — **53 absent**, including every `_multi` batch getter and all of
   `selection_gesture` / `kitty_graphics` / `color_parse` / `terminal_select_*`.
   That is a latent fault, not a build break: `@Native` resolution is lazy even in
   AOT (verified with `dart build cli`, not just JIT), so the app loads fine and
   throws `ArgumentError: Couldn't resolve native function …` at the first call of
   each absent one — on device only. Nothing in the fork's wrappers or `app/lib`
   called any of the 53, which is why it never showed up.
   `scripts/build-ghostty-ios.sh` now takes the upstream v0.1.4 asset (all 106
   present) and restamps `minos`; its ABI check diffs the dylib's exports against
   the resolved bindings so this cannot recur silently. Re-diff on every ghostty
   bump remains the rule.
8. **PTY static-link question — settled and fixed** (open question 1).
   `portable_pty-v0.0.6+antgrid.2` ships dynamic iOS payloads; a cold-cache
   simulator build resolves the download and archives. Keep
   `app/.prebuilt/ios-arm64/` unless the fork's vte `ios-arm64` job stamps a low
   enough `minos` itself.
9. **Store gates — verified.** Run 31364897662 (`5ddaf12f`) archived and uploaded
   to TestFlight with no ITMS rejection. Note what that does *not* cover: the
   upload happened with the stale 102-symbol dylib, and ITMS validation cannot see
   a lazily-resolved missing symbol. Runtime behaviour of the v0.1.4 dylib on a
   physical device is still unverified — the terminal render path has only been
   exercised on macOS and the simulator.
