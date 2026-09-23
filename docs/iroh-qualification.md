# Iroh qualification

Current checkpoint: 2026-09-22. **Release remains unqualified.**

Remote application payloads require native Iroh plus E2E encryption. The central WebSocket is control-only. Peer-frame v3 is a coordinated beta cutover: v2 is rejected and no compatibility decoder, route alias, payload fallback, or mixed-version rollout switch exists. Existing endpoint registrations and keys remain valid.

The [native follow-up plan](native-transport-followup-plan.md) defines this pass; the [simplification ledger](iroh-simplification-ledger.md) records staged commits and exact results; [operations](iroh-operations.md) covers local evidence and future rollout work.

## 2026-09-22 follow-up evidence

| Gate | Result | Boundary |
| --- | --- | --- |
| Self-contained serialized eval sweep | 100 passed, five declared skips, zero failed | Includes central control, native direct loopback, real HTTP/OAuth/Prisma authorization, host/project/file/terminal/Git/preview/session behavior, and current-protocol recovery. Explicit native-DLL and Rust-relay probes are separate. |
| Dart/Bun native interop and resume | 17 passed, one declared skip | Production Dart `iroh_quic` against `@number0/iroh`, with three native/E2E resume cycles and retained project bindings. Direct loopback using an existing built Windows DLL. |
| Seeded native fault soak | Passed: one test, 1,830 assertions, 1,800.77 seconds; seed `0x41c6ce57` | Direct loopback only. Tracks owned cycles, central/native faults, host restart, duplicate mutations, settled relay sessions, and process RSS. |
| Real backend plus native host | Passed; current revocation closure about 21.95 seconds | Real device OAuth, enrollment, authorization refresh, two projects, central outage, and native revocation. Direct loopback. |
| Rust real-backend relay probe | No qualifying result in this pass | The explicit attempt timed out at 100 seconds. The required prebuilt `real_backend_gate` probe was not qualified in this environment. |

Component gates and the few non-clean broad-suite results are recorded without promotion in the simplification ledger. WAN, blocked UDP, forced-relay native QUIC, physical-device backgrounding, sleep/wake, platform packaging, and comparative performance remain unqualified.

## Historical executed evidence and its limits

These are recorded results from September 14-15, not checks rerun whenever this
file changes. The ledger records component gates and subsequent fixes; a clean
full E2E sweep after all fixes remains outstanding.

| Gate | Recorded result | Boundary |
| --- | --- | --- |
| Real HTTP authorization | 25 assertions passed | Actual Hono/Better Auth and PostgreSQL: credential/device binding, sibling and cross-account denial, dual signatures, replay, rotation/history, snapshots and revocation/outbox enqueue. No native payloads. |
| Backend plus native HostServer | Passed; revocation closed the pair after 19.95 seconds | Real OAuth/enrollment/leases, signed E2E, two real projects on one direct loopback connection during central outage. Central welcome was controlled and omitted stream acknowledgements; app driver was handwritten, not Flutter. |
| Native host smoke, source and compiled | Passed | Terminal I/O and frame ACKs, managed-checkout Git, two projects, central outage and immediate remote-access-off. Authorization fixtures. Binds `@number0/iroh` on both ends, so it does not cross the Dart binding boundary. |
| Cross-binding interop, production transports | Passed 2026-09-15 | Production Dart `IrohPeerLink`/`MachineSession` over `iroh_quic` 1.0.3 against a production `IrohRelayClient` host over `@number0/iroh` 1.1.0: signed E2E, two projects, managed-worktree Git, terminal input/frames, central outage, and remote-access-off closing the native link. Authorization fixtures; loopback with relays disabled, so no forced-relay or WAN evidence. Prebuilt CLI library, not the Flutter source build. |
| Rust relay | Six fence/accounting tests, one trusted-TLS gate, one cleartext gate and two configuration tests passed | Published upstream 1.2.0, actual 1.0.0 client protocol compatibility, account isolation, signed disconnect, blocked destination writes denied after revocation, expiry/permits and concurrent byte attribution. Controlled backend responder. The cleartext gate covers the local-development `devInsecureHttp` mode only — real upstream clients relay packets and admission still denies an unknown endpoint with TLS off. That mode is a development convenience and carries no deployment qualification. The custom Rust relay itself is retired by Stage C; this row is a historical record of the design it replaced, not current evidence. |
| Real backend plus relay | 11 assertions passed | Actual OAuth/Prisma enrollment, signed admission, trusted TLS packets, unknown endpoint denial and revocation closing both peers within 60 seconds. Empty outbox targets isolate the lease backstop; this does not prove push delivery or native QUIC forced relay. The `bothConnectionsClosed` guarantee this exercised is dropped for good under the stock relay — see the reversal note below. |
| Windows packaging | Full debug Flutter build and compiled Dart native smoke passed | Source-built DLL included beside the app; explicit-path smoke checks echo, malformed lengths, extra streams and revoked sends. No signed installer qualification. |
| Download site | Build and browser contracts: 38 passed, two skipped | Apple Silicon download link checked; release responses and installer requests were intercepted. No installer integrity evidence. |
| Android resume | Three emulator cycles, 2.754-3.256 seconds to E2E; user reported two minutes backgrounded successfully | Local WebSocket smoke. User run supplied no additional measurements. Physical devices, native resume and desktop sleep/wake remain unqualified. |

## Reproduce current gates

Run workspace scripts from the repository root. Dart/Flutter analysis and CLI
checks must run serially; never run bare root `bun test`.

- `bun run --filter antgrid-bridge qualify:iroh-host`
- `bun run --filter antgrid-bridge qualify:iroh-interop` — the cross-binding gate; needs the Dart native library, see the [transport README](../packages/antgrid_peer_transport/README.md).
- `bun run --filter antgrid-evals test:evals:iroh-authorization`
- `bun run --filter antgrid-evals test:evals:iroh-host-authorization`
- Resolve the stock relay from `ANTGRID_IROH_RELAY_BIN`, or `iroh-relay` on `PATH` (`cargo install iroh-relay --version 1.2.0 --locked --features server`), then run `bun run --filter antgrid-evals test:evals:iroh-relay-authorization`.
- The stock relay's `access.http` config lives at `deploy/iroh/relay.example.toml`; its admission design and accepted losses are in [the transport reduction plan](iroh-transport-reduction-plan.md#stage-c-stock-iroh-relay).
- [Pure-Dart native smoke](../packages/antgrid_peer_transport/README.md) exercises the production record adapter with synthetic admission.
- `bun run scripts/check-iroh-packaging.ts` verifies active Flutter sources against [reviewed integrity manifests](../scripts/iroh-packaging/README.md).

Backend gates require the existing PostgreSQL/Prisma test prerequisites. Native
smokes require the correct native library; fixture gates do not replace combined
backend or physical packaging tests.

## Packaging evidence and remaining checks

Reviewed bindings are `@number0/iroh` 1.1.0, `iroh_quic`/`iroh_flutter` 1.0.3 and
FRB 2.12.0. Exact dependency and source hashes belong in committed lockfiles and
integrity manifests. Run the packaging guard after dependency resolution and
after building; never regenerate its baseline from a changed build cache.

Flutter builds the published plugin's Rust source. This differs from the signed
prebuilt used by the CLI prototype. Upstream setup verifies detached Ed25519
signatures; never use `--no-verify`. Existing cached files are not fresh integrity
evidence. Verify the adjacent packaged artifact and smoke with an empty cache.
The recorded Windows prebuilt digest does not authenticate source-built DLLs.

The Windows source build used Rust 1.98.1; source hashes remained unchanged.
A workspace pub cache avoided an upstream hidden-folder symlink resolver issue.
Normal development subsequently required rustup on PATH and Visual Studio ATL;
the complete debug app then built. Windows/Linux initialization selects explicit
bundled paths and Android opens the packaged library name. Apple bundled-only
loading needs a supported, verified path/API: default upstream resolution can
prefer development/cache libraries, and direct generated runtime initialization
does not establish the public runtime's initialized state.

Still verify locked Rust resolution/compiler provenance and final library hashes,
symbols, ABI, package signatures and clean-cache native loading for each target:
Windows x64 MSIX, Linux x64 AppImage/baseline linker compatibility, signed and
notarized Apple Silicon app, and supported physical Android/iOS architectures.
Check every bundled Mach-O, not only app and bridge executables. Intel builds and
universal assembly are removed; no historical-client transition is required.
Local-network permission denial/resume and release-mode crash resistance remain
physical packaging gates. Upstream release panic behavior can terminate a process.

## Security and lifecycle qualification still required

The integration review found and corrected real OAuth metadata parsing, native
hello naming, record/header size accounting, write deadlines, independent local
stream readiness and late unconfirmed native carriers blocking WebSocket hello.
Dart selection captures peer identity, registration generation and approved-relay
configuration across awaits; handshake cancellation and leases fence late crypto
completion and key ownership. These fixes and unit gates do not prove every
asynchronous interleaving.

Unknown native failure strings remain terminal because the binding lacks verified
typed close causes. Authentication, revocation and protocol failures must never
cause fallback. Upstream-owned key-copy zeroization and precise path-byte telemetry
remain unsupported or unverified. FRB runtime disposal is process-final, never
per-peer cleanup. Endpoint history prohibits revoked seed reuse; reseeding and
re-enrollment UX still needs qualification. Upgraded local software must provision
protected keys or fail closed, even while central control is unavailable.

Qualify real Dart/app-to-bridge QUIC/E2E over direct WAN and the self-hosted forced
relay; multiple machines/apps/projects, all feature services and checkout-safe
hydration; queued-data expiry and credential/endpoint/policy rotation during each
await; admission/disconnect races, lost pushes, backend/central/relay outages and
remote-access-off. Exercise late dials/accepts, cancellation under stream mutex
contention, UDP blocked at either end, network transitions, background/resume,
long sleep, repeated reconnects and mixed versions. Never replay pending input or
non-idempotent commands after peer loss.

**Reversed 2026-09-23 (Stage C).** The custom relay existed because stock
upstream admission plus an asynchronous disconnect cannot fence revocation: a
device revoked after authorization but before registry insertion stays
connected. That race still exists with `access.http` — upstream authorizes the
upgraded connection and only then registers the client
(`iroh-relay` 1.2.0 `src/server/http_server.rs`) — and Stage C does not close it.
Instead it drops relay-side revocation, together with the account-wide
generation fences and destination retirement that enforced it. A device
revoked while connected, including inside that window, keeps its relay
connection; the bridge closes the peer instead, immediately on the
`peer-policy-changed` push or at the latest when the lease expires (60
seconds). This is judged sufficient because the relay forwards only
ciphertext, and a bridge accepts only endpoint IDs in its own authorization
snapshot while the app dials only the bridge it enrolled with. Losing
per-account registries lets any admitted endpoint address a known endpoint ID:
spam/DoS rather than disclosure, plus one web lease refresh per foreign dial,
which the bridge's per-endpoint accept pre-filter bounds. See
[the transport reduction plan](iroh-transport-reduction-plan.md#stage-c-stock-iroh-relay)
for the full accepted-losses list.
Still qualify Linux container execution/signatures, distributed outbox delivery,
configuration invalidation across processes, retained outbox cleanup, billing
invalidation, cold-start/rotation races and resource ceilings under load. Collect
third-party source license texts before release.

Dedicated control-authentication/discovery, E2E, project-binding and usable-terminal
timings, CPU/memory and path-byte measurements remain incomplete. Missing telemetry
must not be interpreted as zero latency or traffic. No performance acceptance
criterion has passed. Use identical workloads with at least 100 connects and
1,000 input samples per network profile, applying every threshold in the approved
plan before staged promotion. Deployment, DNS and secrets remain operator actions.

## Historical evidence

The standalone Windows prototype passed encrypted terminal/rekey, identity denial,
record/stream rejection and compiled Bun/Dart interoperability checks. It used
fixture authorization/project handlers and a local WebSocket shim; those results
are not production-host qualification. Its source, dependency graphs and detailed
results, plus the superseded integration/packaging/upstream reviews, remain in Git
at `9ed88a01`. The retired prototype path was `scripts/iroh-qualification/`.
Current implementation evidence belongs above and in the ledger; local captures
remain ignored artifacts.

The ownership simplification results and outstanding qualification are recorded in `iroh-simplification-ledger.md`. Native initialization uses a provisional 30-second budget and dialing uses 15 seconds; neither value constitutes WAN or forced-relay performance qualification.
