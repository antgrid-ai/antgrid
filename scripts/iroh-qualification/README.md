# Iroh upstream qualification probes

This historical standalone ELv2 prototype is outside the production Bun
workspaces. Install here explicitly. Production integration now lives in the
bridge and `packages/antgrid_peer_transport`; see the migration task ledger.
The gate and measured results are in [the qualification report](../../docs/iroh-qualification.md).

The basic `interop` probe exchanges synthetic bytes. The `prototype` additionally
uses Antgrid's signed E2E/session drivers, binds two fixture projects and runs
allowlisted arithmetic commands in real PTYs. Account inventory, central control
admission and project dispatch are fixtures; production authorization is not
qualified. Passing these probes does not pass the production migration gate.

## Encrypted terminal qualification

Install the root Bun workspace dependencies as well as this standalone project's
dependencies: the prototype imports the existing bridge implementation directly.
Complete the native setup under **Source smoke** below, then run:

```powershell
bun run --cwd scripts/iroh-qualification test
bun run --cwd scripts/iroh-qualification typecheck
dart analyze scripts/iroh-qualification/dart
bun run --cwd scripts/iroh-qualification qualify
```

`qualify` runs native cases serially and writes `.tmp/iroh-qualification/prototype-results.json`:

- Signed E2E establishment → two project streams → terminal input and screen
  frames → project reuse → rekey → more terminal input on the same Iroh connection.
- Wrong agent signing key and wrong app signing key: no E2E establishment or commands.
- Oversized native record, incorrect destination and unexpected additional bidirectional stream, tested against both receivers:
  explicit rejection before any terminal input.
- Peer disconnect during an RPC: `E_SESSION_DOWN`, with the session no longer established.

Each child has a process deadline. `IROH_QUALIFICATION_CASE` selects a single
case for `prototype`; omit it for the terminal path. Project terminals run in a
unique directory under the root `.tmp/iroh-qualification`; only fixture public
identity inventory is written there. The terminal handler permits two arithmetic
expressions and checks their computed output, rather than accepting the shell's
echo of input as execution evidence. It asserts the existing remote (`relay`)
source classification, two establishment events and exactly three terminal inputs.

`dart/lib/peer_link.dart` is the Flutter-free prototype adapter shared with the
CLI. It supplies bounded route records to unchanged `MachineSession` and
`AppSessionHandshaker`. The bridge uses a private, process-local WebSocket shim
to feed unchanged `RelayClient`; only encrypted route frames and handshake frames
cross Iroh. Central control replies are fixtures. There is no remote WebSocket
payload fallback in this experiment, and it never uses the bridge's `LocalListener`.
These adapters are not the production transport abstraction.

For the compiled encrypted prototype, use the same setup and verified adjacent
DLL as **Compiled Windows smoke**, substituting these build/run commands:

```powershell
bun build scripts/iroh-qualification/prototype.ts --compile --outfile .tmp/iroh-qualification/packaged/prototype.exe
# Run this while IROH_QUALIFICATION_DART still names the SDK dart.exe.
& $env:IROH_QUALIFICATION_DART compile exe scripts/iroh-qualification/dart/bin/prototype.dart -o .tmp/iroh-qualification/packaged/dart-prototype.exe
$env:IROH_QUALIFICATION_DART = Join-Path (Get-Location) '.tmp/iroh-qualification/packaged/dart-prototype.exe'
$env:IROH_QUALIFICATION_COMPILED = '1'
$env:IROHDART_CACHE_DIR = Join-Path (Get-Location) '.tmp/iroh-qualification/empty-cache'
& .tmp/iroh-qualification/packaged/prototype.exe
```

The compiled Bun prototype embeds Iroh and the existing PTY native dependency.
Physical devices, self-hosted/forced relay, secure enrollment, lease/revocation,
Flutter resume/rendering, other platforms and performance thresholds remain unqualified.

## Source smoke

Requires Bun and Dart 3.12 or later. Use the exact dependencies in both lockfiles.
`flutter_rust_bridge` is pinned to the upstream generated-code version, since
`iroh_quic`'s semver range also allows incompatible codegen/runtime versions.

From the repository root in PowerShell:

```powershell
bun install --cwd scripts/iroh-qualification --frozen-lockfile --ignore-scripts
dart pub get --directory scripts/iroh-qualification/dart --enforce-lockfile
$env:IROHDART_CACHE_DIR = Join-Path (Get-Location) '.tmp/iroh-qualification/native'
Push-Location scripts/iroh-qualification/dart
dart run iroh_quic:setup
Pop-Location
$irohDartLauncher = (Get-Command dart).Source
$env:IROH_QUALIFICATION_DART = if ($irohDartLauncher.EndsWith('.bat')) {
  Join-Path (Split-Path $irohDartLauncher) 'cache/dart-sdk/bin/dart.exe'
} else { $irohDartLauncher }
bun run --cwd scripts/iroh-qualification probe
bun run --cwd scripts/iroh-qualification interop
```

On Windows, `IROH_QUALIFICATION_DART` must point to the SDK's **dart.exe**, not
Flutter's `dart.bat`: the harness spawns an executable without a shell. The
commands above resolve that Flutter SDK layout. Coordinate Dart/Flutter
commands with other sessions as required by the root repository instructions.
The native setup verifies the upstream Ed25519 signature; never use `--no-verify`.

The Bun endpoint uses the minimal preset; the Dart endpoint disables relays and
replaces public address lookup with an empty callback. Both peers verify the
authenticated endpoint ID and ALPN. A single bidirectional stream carries a
four-byte big-endian length plus a bounded 4096-byte synthetic record. The sender
splits the prefix across writes, the receiver uses bounded exact reads, and the
echo coalesces prefix and body. This is an initial native stream smoke, not the
complete production framing conformance suite. A process deadline fails hangs.

## Compiled Windows smoke

After source setup, with `IROH_QUALIFICATION_DART` still pointing to `dart.exe`:

```powershell
New-Item -ItemType Directory -Force .tmp/iroh-qualification/packaged | Out-Null
bun build scripts/iroh-qualification/interop.ts --compile --outfile .tmp/iroh-qualification/packaged/interop.exe
& $env:IROH_QUALIFICATION_DART compile exe scripts/iroh-qualification/dart/bin/interop.dart -o .tmp/iroh-qualification/packaged/dart-client.exe
Copy-Item .tmp/iroh-qualification/native/iroh_quic/v1.0.3/x86_64-pc-windows-msvc/irohdart_ffi.dll .tmp/iroh-qualification/packaged/irohdart_ffi.dll
$env:IROH_QUALIFICATION_DART = Join-Path (Get-Location) '.tmp/iroh-qualification/packaged/dart-client.exe'
$env:IROH_QUALIFICATION_COMPILED = '1'
$env:IROHDART_CACHE_DIR = Join-Path (Get-Location) '.tmp/iroh-qualification/empty-cache'
& .tmp/iroh-qualification/packaged/interop.exe
```

The compiled Bun executable embeds the upstream N-API addon. The compiled Dart
client loads the verified DLL beside its executable; the empty cache override
prevents an installed native cache from hiding a packaging omission. Compare the
DLL digest with `native-artifacts.json` before sharing a package.

The Dart CLI calls upstream `RustLib.dispose()` after closing its endpoint to
release FFI ports and let the process exit. This is runtime-final teardown, not a
per-peer disconnect API; its suitability for Flutter lifecycle handling and
reinitialization is not qualified. No upstream files are modified.

Serial static check: `dart analyze scripts/iroh-qualification/dart`.
Do not add these network/native probes to the root unit-test sweep.
