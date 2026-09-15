# Iroh migration qualification

Checkpoint: 2026-09-14. **Release gate not passed. Branch implementation is in progress.**

Production-path implementation and current checks are tracked in the
[task ledger](iroh-migration-ledger.md); [operations](iroh-operations.md) describes
configuration and outstanding deployment gates. The remaining sections preserve
prototype evidence and must not be read as qualification of the new integration.

The user has approved implementing the full migration on this isolated branch,
then qualifying it in staging before production rollout. Physical Android/iOS,
remaining release targets, security and performance remain **release gates**;
they no longer block implementation on the branch. See the
[continuation handoff](iroh-migration-handoff.md) for the latest sequencing decision.
This checkpoint now includes a Windows encrypted-terminal prototype
using the existing E2E/session drivers, real PTYs, project multiplexing and rekey,
plus compiled packaging and rejection tests. It uses fixtures for central
admission, account inventory and project dispatch. No performance acceptance
criterion or mobile/forced-relay release gate has been measured.

## Locked migration decisions

- Scope L, beginning with an M-sized qualification prototype. Use upstream
  `@number0/iroh`, Flutter-free `iroh_quic`, and `iroh_flutter` packaging. A
  required missing upstream capability blocks qualification; no binding fork.
- Retain the authenticated central WebSocket for inventory, presence and
  revocation. Self-host Iroh relays with authenticated endpoint admission,
  active disconnect and bounded authorization lifetimes.
- Preserve application E2E, signed transcript bytes, establishment/rekey,
  channel scheduling, frame/reassembly budgets and feature-service behavior.
- One endpoint per active process/account enrollment; one app-initiated
  connection per app–machine pair reused across projects. ALPN `antgrid/peer/1`;
  one reliable bidirectional QUIC stream, four-byte unsigned big-endian record
  lengths around existing route frames. Validate length before allocation,
  destination, frame content and unexpected streams. Path changes do not
  establish new E2E sessions or invalidate project bindings.
- Modes: `websocket`, `iroh-preferred`, test-only `iroh-only`. Preferred allows
  five seconds before choosing payload fallback. Only the selected generation
  may handshake/write; no opportunistic upgrade of a healthy WebSocket session.
  Denial, revocation and protocol violations are terminal. Fail pending actions
  with connection-lost/unknown-outcome on replacement; never replay commands.
- Separate endpoint enrollment keys from application identity keys. Bind each
  enrollment to the credential's actual device using single-use expiring,
  domain-separated challenges signed by both keys. Inventory carries endpoint
  ID, registration generation and authenticated capabilities. Rotation revokes
  old sessions. Keep desktop-controller and local-bridge identities distinct.
- Refresh authoritative device/peer authorization every 20 seconds while remote
  sessions are active. Maximum 60-second monotonic lease from request start;
  failed refreshes, disk cache, pushes and peer traffic cannot renew it. Require
  fresh authorization after restart/resume. Reject stale generations. On expiry
  or revocation block inbound commands/outbound data, clear queues and keys,
  and close affected peers. Central disconnect alone does not immediately kill
  a healthy leased direct session.
- Every remote transport enforces account trust, live machine remote-access
  policy, `seenProjects`, `isSafeProjectId` and checkout capabilities. Direct
  traffic must never enter the loopback exemption. Local switch-off is immediate.
- Embed upstream `iroh-relay` in an Antgrid Rust service, TLS/443 externally;
  private authenticated administration. Fail-closed admission checks have a
  two-second backend timeout. Fence admission/revocation races, disconnect on
  every configured instance, and revalidate open endpoints within 60 seconds.
  Bound connections, pending admissions and traffic; collect usage without new
  billing quotas. Approved environment-specific relays only; no implicit public
  relay fallback and no customer-held shared admission secret.
- Drop Intel macOS for new releases after qualification. Coordinate bridge
  compilation, Flutter/native packaging, metadata and updater eligibility so
  existing Intel installations cannot receive incompatible updates. Retain
  Apple Silicon and other existing targets. Current release files are unchanged
  at this incomplete gate.
- Keep ELv2 implementation out of Apache packages. Browser P2P, central-WebSocket
  removal, custom UDP and additional QUIC streams are outside scope.

## Reproducible implementation

[`scripts/iroh-qualification`](../scripts/iroh-qualification/README.md) is a
standalone ELv2 project outside production workspaces. It includes exact Bun/pub
lockfiles, a native bind/close probe, a Bun listener and a Flutter-free Dart
initiator, compilation instructions and the verified Windows native digest.
The encrypted prototype imports production bridge and pure-Dart client code
without modifying it. Its adapters and fixture handlers remain isolated from
production builds and the root test sweep.

### Encrypted prototype results

`bun run --cwd scripts/iroh-qualification qualify` passed all ten native
scenarios on Windows x64. Its machine-readable output is generated at
`.tmp/iroh-qualification/prototype-results.json`. The final terminal run was also
compiled and passed with the Dart native cache redirected to an empty directory.

| Scenario | Verified behavior |
|---|---|
| Encrypted terminal | Existing `AppSessionHandshaker` ↔ `RelayClient` signed E2E and confirmation; unchanged `MachineSession` and `StreamMux` carry two projects |
| Real terminal | Existing `TerminalSession` PTYs and `TerminalFrameSource` produce current-version screen frames; the client checks computed arithmetic output |
| Project reuse and rekey | Same Iroh connection and project binding; two establishments and exactly three terminal inputs, including input after rekey |
| Wrong agent identity | Signature rejected; zero establishments, project opens or terminal inputs |
| Wrong app identity | Signature rejected; zero establishments, project opens or terminal inputs |
| Oversized record | Both Bun and Dart reject the native four-byte length before body allocation |
| Wrong destination | Both endpoints reject valid route frames addressed elsewhere before dispatch |
| Extra QUIC stream | Both endpoints reject an additional bidirectional stream before terminal input |
| Connection loss | Pending RPC fails with existing `E_SESSION_DOWN`; client session becomes unestablished |

The final compiled terminal run sent 25 route frames and received 22, with
2,399 peak queued record bytes in the Bun adapter. These are smoke observations,
not throughput or latency measurements. No performance claim follows from them.

The seven record-unit cases also passed: invalid bounds, fragmented/coalesced
reads, truncated EOF, bounded queue overflow, queued-write discard and fencing an
in-flight read after close. TypeScript typechecking and Dart static analysis pass.
The reused bridge E2E regression suite passes (19 tests), as do 36 selected
pure-Dart handshake, E2E-vector, rekey and project-binding regression tests.

**Qualification boundary:** account inventory and control admission are fixtures;
the bridge adapter answers local control messages and maps authenticated Iroh
peers onto the existing remote route source. It uses a local WebSocket shim so
the production session driver stays unchanged. Project dispatch and terminal
subscriptions are minimal fixture handlers, not `HostServer`/`agent-core`.
The Dart adapter subclasses `RelayService` as a prototype seam. This verifies
existing encrypted-session interoperability over Iroh, but not production
enrollment, checkout authorization, revocation/leases, fallback or full hydration.
Screen-frame transport is tested; physical Flutter/Ghostty rendering is not.

Versions tested: Bun 1.3.14, Dart SDK 3.13.1, `@number0/iroh` 1.1.0,
`iroh_quic` 1.0.3, `flutter_rust_bridge` 2.12.0, Windows x64. The Dart package's
shipped Rust lockfile resolves Iroh 1.0.0. The JS package declares Iroh 1.0.0
with Cargo semver semantics; do not infer its exact compiled core version from
that declaration. NPM artifact integrity is pinned in the probe's Bun lockfile.

| Check | Observed result |
|---|---|
| Upstream Windows Dart native download | Ed25519 signature verified by upstream setup; SHA-256 recorded in `native-artifacts.json` |
| Bun native endpoint | Bind and close pass with minimal preset |
| Bun ↔ Dart source probe | Pass: authenticated endpoint IDs on both ends, exact ALPN, bidirectional stream, 4096 synthetic bytes echoed |
| Stream reads | Pass: split prefix writes, bounded exact prefix/body reads, coalesced echo; not exhaustive framing conformance |
| Compiled Bun ↔ compiled Dart | Pass with embedded N-API addon and DLL beside Dart executable; native cache redirected to empty directory |
| Final successful compiled run | QUIC counters: TX 21,910 bytes / 38 datagrams; RX 23,173 bytes / 36 datagrams; zero reported lost packets/bytes. These include protocol overhead, are not server payload metrics and are not a benchmark |
| Dart CLI shutdown | Pass only after closing endpoint and disposing upstream FRB runtime ports |
| Dart static analysis | `dart analyze scripts/iroh-qualification/dart`: no issues |
| Physical Android inventory | `adb devices -l`: no attached devices |
| Physical iOS, macOS/Linux runners, self-hosted relay | Not available through this session; not tested |

The experiments use loopback addresses, disabled relays and no public address
lookup. They establish local application E2E interoperability but cannot establish
NAT traversal, relay interoperability, mobile packaging or production remote
authorization behavior.

### Findings to carry into the prototype

The published JS manifest points to `iroh-js/index.js` and
`iroh-js/index.d.ts`, while the tarball ships them at its root. Bun's ordinary
loader succeeded despite this mismatch; the probe uses the shipped `index.js`
subpath explicitly. `createRequire` prevented native embedding in the compiled
probe; static `require` let Bun embed the addon successfully. Neither finding
required patching the upstream package.

The Dart package allows FRB `^2.12.0`, which resolved to 2.13.0 in the initial
dependency resolution. Pinning 2.12.0 matches generated-code/native runtime
expectations. No 2.13.0 runtime interoperability result is claimed.

`Endpoint.close()` completed but the Dart CLI remained alive beyond the probe's
20-second deadline. Calling upstream generated `RustLib.dispose()` released
runtime ports and allowed clean exit. It is an internal-package import and
runtime-final teardown, not a qualified per-peer or Flutter-resume solution.
Endpoint/callback disposal under repeated enrollment and network lifecycle
changes remains a gate item.

The published Dart API exposes remote identity, custom relays, secret-key
import/export/signing, stream I/O, close, path events and aggregate QUIC
counters. Presence of these APIs is source evidence, not behavioral qualification.
Cancellation while an operation holds a stream mutex, independent dial
cancellation on a shared endpoint, path accounting and callback cleanup need
targeted stress tests. No definitive upstream capability blocker is asserted
from an API search alone.

Sources inspected: [JS package](https://www.npmjs.com/package/@number0/iroh/v/1.1.0),
[Dart package](https://pub.dev/packages/iroh_quic/versions/1.0.3),
[Dart source snapshot](https://github.com/snowpinelabs/iroh_dart/tree/5b2d1e899aad081b0c4e3e9b675977ceffdfd9e7),
[native release](https://github.com/snowpinelabs/iroh_dart/releases/tag/v1.0.3).
Published package tarballs, rather than mutable branch declarations, supplied
the probe's native/API inputs.

## Work still required before passing the gate

1. Extend the working encrypted-terminal prototype to direct WAN and forced
   self-hosted relay paths, then replace fixture project/control handlers with
   the complete host lifecycle. Qualify checkout routing and hydration through
   the actual feature services. The current loopback result alone does not
   qualify those behaviors or performance.
2. Package and run on physical Android/iOS, Windows x64, Linux x64 and Apple
   Silicon, plus existing mobile architectures. Pin and verify all Flutter and
   native artifacts. Verify secure endpoint-key persistence, identity, custom
   relay selection, cancellation, shutdown, path metrics and network changes.
3. Qualify endpoint impersonation, enrollment binding, generation races,
   revocation during admission and active direct/relayed traffic, lost pushes,
   backend outages, lease expiry during queued bulk, and remote-access-off.
   Then implement production abstractions, enrollment/snapshots, leases,
   self-hosted relay administration, rollout selection and lifecycle handling.
4. Complete framing/E2E vectors, fragmentation/coalescing/malformed lengths,
   queue pressure, rekey, stale writers, multiple peers/projects, bridge restart,
   checkout routing and non-idempotent action failures. Exercise UDP blocked at
   either/both ends, relay outage, Wi-Fi/mobile transitions, background/resume,
   sleep/wake, reconnects and mixed WebSocket versions. Run workspace gates,
   pure-Dart tests, explicit E2E evals and serial Dart/Flutter analysis.
5. Measure identical devices/workloads with at least 100 connects and 1,000
   input samples per network profile. Instrument control authentication,
   discovery, peer/E2E establishment, project binding and usable terminal,
   input-to-screen p50/p95, direct/relay bytes, fallback reasons, CPU and memory
   without payload logging. Require ≥95% lower steady-state server payload
   bytes on direct-capable transfers, lower direct-WAN p95 interaction latency,
   ≤10% startup/forced-relay p95 regression, ≤1 percentage-point connection
   success regression, and no duplicate commands, bypasses, unbounded queues
   or native crashes.

After qualification, deploy additive backend support, then internal, 1%, 10%,
50%, 100% cohorts with passing gates and ≥48 hours of healthy telemetry before
each promotion. Release operators own DNS, secrets and production deployment.
Rollback disables preference for new sessions and reconnects without replay;
retain additive database fields. Retire WebSocket payloads only after two
qualified releases and 14 consecutive days with ≥50% lower server payload bytes,
<1% fallback and supported-client compatibility accounted for. Keep central
control WebSocket traffic. Architecture/protocol/runbook changes must accompany
the actual production implementation, not describe the probe as shipped behavior.
