# Iroh packaging review

Reviewed 2026-09-14 using repository release configuration and the installed,
published `iroh_flutter` / `iroh_quic` 1.0.3 package source. No release workflow,
dependency lockfile, package cache, deployment or signing secret was modified.
This is source inspection; no Flutter build or physical-device test ran in this
review. Native transport preference must remain disabled pending qualification.

## Pins and build paths

| Component | Inspected behavior | Qualification gap |
| --- | --- | --- |
| Bridge | `bridge/package.json` pins `@number0/iroh` 1.1.0. `IrohRelayClient` dynamically imports the literal `@number0/iroh/index.js`; Bun compilation can include this dependency. | Release workflows smoke hook and MCP entry points, which do not prove native Iroh loading. Run compiled endpoint bind/close and encrypted peer exchange from an isolated directory without source dependencies on every target. |
| App Dart | `app/pubspec.lock` records pub archive hashes for `iroh_flutter` and `iroh_quic` 1.0.3. App and ELv2 transport manifests pin the relevant package versions. | Release `flutter pub get` does not use lock enforcement. Require resolved pins and hashes to match the reviewed lockfile, including FRB 2.12.0. |
| Flutter native | Upstream plugin packages contain `rust/Cargo.toml` and `Cargo.lock`; Windows CMake bundles `irohdart_ffi.dll`, Linux CMake bundles the native library, and Apple podspecs force-load the Rust static library so process FFI symbols survive stripping. | This is a source build, not the prototype prebuilt DLL installation. Validate actual final package inclusion and symbol resolution; copying the prototype DLL is not the Flutter packaging strategy. |
| Rust reproducibility | Upstream manifest exactly pins FRB 2.12.0 but allows Iroh `1.0`; its published Cargo lock constrains the resolved graph. Vendored Cargokit invokes `cargo build` without `--locked` by default and chooses the stable toolchain. | Freeze the Rust compiler and enforce unchanged Cargo lock resolution through supported build configuration before release. A shipped lockfile alone does not prove a reproducible build. Do not patch or fork the upstream binding to claim this gate. |
| Pure Dart CLI | Upstream `iroh_quic:setup` downloads versioned desktop prebuilts and verifies an Ed25519 detached signature. `native-artifacts.json` records the previously qualified Windows DLL digest only. | No pinned artifact digest/signature evidence is recorded for Linux x64 or macOS arm64 CLI libraries. Setup skips already-installed files, so a preexisting cache is not fresh integrity evidence. Verify the actual adjacent packaged binary and detached signature, then smoke with an empty cache. |

The upstream prebuilt verification key in the reviewed 1.0.3 source is
`74b7c73d253932835af9e3f63c99135e85aaff6a8ab2a7b0de0558a453246743`.
Its installer verifies raw detached Ed25519 signatures over the artifact bytes.
Never use `--no-verify`. This signature mechanism applies to upstream prebuilts;
source-built Flutter outputs need their own recorded provenance and final
platform signing/integrity checks. Do not compare a source-built DLL against
the prototype prebuilt digest and label a mismatch a supply-chain failure.

The desktop workflow currently uses `bun install --ignore-scripts` and
`flutter pub get`; changing them to frozen/enforced lock resolution is a parent
workflow task. Rust setup on desktop selects mutable `stable`, while the Android
setup also references the mutable toolchain action branch. Capturing the actual
compiler, resolved dependency graph and native output digest is needed for each
qualified artifact.

## Apple Silicon migration

`build-desktop.yml` now compiles only `bun-darwin-arm64`, publishes
`antgrid-macos-arm64.dmg` and `appcast-macos-arm64.xml`, and checks both bridge
and app executable architectures with `lipo`. `app/macos/Podfile` explicitly
sets pod target `ARCHS` to `arm64`; this carries through Cargokit's architecture
input despite the upstream podspec's stale comment describing a universal build.
No Intel bridge compilation or universal assembly remains in this workflow.
The remaining workflow `x86_64` strings describe the Linux AppImage target.

Inspect the final `.app` frameworks and native libraries for architecture and
signing as well as the two executables. The two current `lipo` assertions do not
cover every bundled Mach-O. Production release qualification must require a
valid signed/notarized output even though the generic workflow supports optional
unsigned builds. No historic Intel client transition is required by this change.

## Platform release gates

- Windows x64: inspect the installed MSIX payload for the plugin DLL, run the
  packaged app's native initialization and transport test, and verify the
  compiled bridge in its packaged location. A successful hook/MCP smoke does
  not load the native endpoint.
- Linux x64: inspect the AppImage's bundled shared libraries and dynamic linker
  dependencies, then exercise native transport on the supported baseline distro
  without development caches. Confirm the Rust toolchain does not silently
  increase the required glibc baseline.
- macOS arm64: build on Apple Silicon, inspect all native architectures and
  exported/force-loaded FFI symbols, then test the signed and notarized `.app`.
- Android/iOS: run existing supported architecture builds and physical-device
  native initialization/network transition tests. Android upstream JNI/context
  initialization and Apple static FFI loading need packaged tests; desktop
  prebuilts do not validate either path.
- All targets: record native library versions, ABI compatibility, artifact
  digests, package signing results and crash-free repeated endpoint lifecycle.
  Upstream Rust release configuration uses `panic = "abort"`; debug tests alone
  do not prove malformed input cannot terminate a release process.

## Deployment boundary

Backend `IROH_RELAY_URLS` and private `PEER_POLICY_TARGETS` are distinct. Empty
defaults do not constitute relay deployment. The upstream service admission,
disconnect-race and resource-control blockers in `iroh-relay-upstream-audit.md`
still prevent declaring a self-hosted relay ready. TLS 443, approved environment
relay maps, service authentication, dashboards and active-disconnect delivery
must be exercised against an actual staged service before preference is enabled.

## Build source integrity guard

Run `bun run scripts/check-iroh-packaging.ts` after Flutter dependency resolution
and again after each Flutter build. It resolves the active plugin through
`app/.dart_tool/package_config.json` using file URLs, including relocated pub
caches. It checks package versions, app lock archive hashes, declared app and
transport pins, generated Dart/Rust FRB versions, and exact SHA-256 digests of
the active plugin's `rust/Cargo.toml` and `rust/Cargo.lock` against
`scripts/iroh-qualification/flutter-source-pins.json`.

The baseline came from the originally installed published `iroh_flutter` 1.0.3
package, before the isolated build cache was selected. Local inspection found
the active isolated cache identical: Cargo lock digest
`3554b2db648edf2ab0009c02ad930010501a214b1eacf53d97d8e1aaf481c030`
and Cargo manifest digest
`6597874c1e976209bfb8fa2ef193a1110c181e8d1ace0d458a8df11cc2b5b183`.
The script passed locally. It does not modify upstream files, generate new pins,
verify final compiled artifacts, or substitute for package signatures. A build
mutation fails comparison rather than silently becoming the new baseline.

## Runtime library selection

Upstream `iroh_quic` 1.0.3 `IrohRuntime._resolveExternalLibrary` checks relative
Rust build directories and the user setup cache before the adjacent library,
Apple process symbols or platform loader. Therefore default `Iroh.init()` does
not guarantee that a Flutter app loads its packaged native artifact. Native ABI
version equality alone does not authenticate the selected bytes.

Public `Iroh.init(libraryPath: absolutePath)` bypasses that search. Windows can
select the DLL adjacent to the installed executable; Linux can select the
bundled `lib/libirohdart_ffi.so`. Both paths need to be passed before any implicit
native initialization. The pure-Dart endpoint owner should accept an injected
runtime initializer so Flutter packaging can own platform-specific paths while
CLI qualification uses an explicitly verified adjacent prebuilt.

The public API does not offer an explicit process-symbol initialization mode
for Apple. The podspec force-loads native symbols into its framework, so an
absolute `iroh_flutter.framework/iroh_flutter` path is a candidate for explicit
loading, but the final framework location, exports and signed `dlopen` behavior
must be verified on macOS/iOS. This review does not qualify that workaround.
Calling generated `RustLib.init` directly is not sufficient: it does not set
the public runtime's initialized flag, and later APIs can reenter default
resolution. Do not change third-party sources or claim bundled-only loading
until the production initializer and physical packaging gate establish it.

## Integration changes after this review

The desktop workflow now installs Rust explicitly, freezes Bun dependency
resolution, and runs a compiled real HostServer/native/E2E smoke before each
platform build. That smoke uses fixture authorization and does not validate the
final Flutter bundle. Upstream source-build reproducibility and final artifact
inspection remain open.

The iOS and macOS app plists now include a local-network usage explanation for
direct connections to development machines. Apple requires this description for
local unicast connections as well as discovery:
[NSLocalNetworkUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription).
Permission-denied/resume behavior still requires physical device qualification.

## Executed Windows source build checkpoint

The default AppData package cache exposed an upstream PowerShell symlink-resolver
failure on hidden folders. `flutter pub get --enforce-lockfile` with the
workspace-local PUB_CACHE avoided it; desktop CI now uses a workspace cache.
Rust was installed in `.tmp/iroh-rust-toolchain` without changing the global PATH;
the official installer matched its published SHA256. The pinned Flutter plugin
built `irohdart_ffi.dll` using rustc1.98.1. Its debug DLL SHA256 was
`07bb17b049f829fa5370b0f3457237bb1b4ab7256835924a2f0d73254c7097a6`.
The before/after source guard passed; Cargo.lock remained byte-identical to the
published package.

A compiled `antgrid_peer_transport/bin/native_smoke.dart` executable loaded that
exact DLL by explicit path and passed echo, malformed length, extra-stream and
revoked-send checks. This is Windows native-plugin build/runtime evidence.
The complete Flutter app build is **unqualified**: the installed Visual Studio
components lack `atlstr.h`, required by `flutter_secure_storage_windows`, and
no final app executable was produced. Remaining platform builds and signed final
bundle verification still require qualified runners.

Production Windows/Linux initialization now passes an explicit bundled library
path; Android explicitly opens the packaged shared-library name. Apple's missing
public process-only selection remains a release gate. The standalone smoke can
accept a library path so qualification cannot silently substitute a cached DLL.

The macOS job retains `macos-15`, currently documented as an arm64 runner by
[GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
and explicitly checks `uname -m` before native dependency installation. Final
app and bridge binaries are also checked with `lipo -archs` for arm64 only.

## Download site contract gate

The separate `site/` project was installed with `bun install --frozen-lockfile`.
Its lockfile remained unchanged (SHA256
`04216C1AB63BA2BA903489290D86E6E68E2C9D617144364FB9185E88144A6FC5`).
With `CI=1`, `bun run test tests/contracts.spec.ts --workers=2` completed with
**38 passed, 2 intentionally skipped**, exit 0. The gate built the Astro site and
started its own preview server; existing-server reuse was disabled. Both desktop
and mobile browser projects exercised the download contracts, including the
Apple Silicon `antgrid-macos-arm64.dmg` link. Installer requests and release API
responses were intercepted by the test fixtures; no release artifacts were
downloaded.

The initial sandboxed attempts could not access the external Playwright Chromium
cache. The pinned browser installation and final test run used authorized cache
access. No site source or lockfile changes were needed for this verification.
This qualifies the site links and browser behavior, not the contents or signatures
of the platform installers.
