# Relay implementation handoff

Implemented 2026-09-14 under `iroh-relay/`; root CI and deployment monitoring are
owned by the integration change. Service and test-only compatibility crates have
separate committed Cargo lockfiles. No upstream source was forked or patched.

The production adapter embeds upstream 1.2.0 authentication, protocol codecs,
client actors, routing registries and byte buckets. Account-scoped registries
and raw I/O generation fences close all account peers on policy invalidation or
lease failure, including recipients holding queued packets from a revoked source.
Backend HMAC admission uses the frozen shared API. Private HMAC administration,
bounded resources, TLS 443 configuration, health/readiness, metadata-only
Prometheus metrics, usage logs and an immutable-base container build are included.

## Executed verification

- `cargo build --locked --manifest-path iroh-relay/compat-client/Cargo.toml`:
  passed using Rust 1.98.1 and two build jobs.
- `cargo test --locked --manifest-path iroh-relay/Cargo.toml -- --nocapture`
  with `ANTGRID_LEGACY_RELAY_CLIENT` pointing at that executable: passed six
  fence/accounting tests and one real TLS integration test. The latter also passed actual
  upstream 1.0.0 signed authentication and packet exchange against service 1.2.0.
- Tests assert cross-account isolation, denied admission, signed disconnect,
  unchanged destination byte count after releasing a revoked blocked transport,
  unaffected other-account ping/pong and connection permit release.
- Byte recording acquires the identity-binding lock before updating totals,
  preventing concurrent admission from double-counting pre-authentication bytes.
  Tests cover concurrent binding, pre/post-authentication totals, disconnect
  retention and rejected anonymous traffic remaining unattributed.
- Test certificates use explicitly configured CA roots. Neither system trust
  stores nor production certificate verification were modified.
- `cargo fmt` completed for both crates. Locked metadata generated the
  third-party inventory; source license-text collection remains a release gate.

## Qualification still required

The original TLS test's HTTP admission responder is controlled. A subsequent
real-backend/service gate passed 11 assertions using actual OAuth/Prisma endpoint
enrollment, signed admission, trusted TLS packet exchange, unknown endpoint
denial and backend revocation closing both account connections within 60 seconds.
Build `examples/real_backend_gate.rs` with the locked Cargo graph, then run
`bun run --filter antgrid-evals test:evals:iroh-relay-authorization`.
Full JS/Dart QUIC forced-relay clients,
physical platforms, Linux container execution, image verification, distributed
outbox behavior, outage/resume paths and prescribed load/performance samples
remain unqualified. The exact old-client test pins protocol-boundary crates,
not the complete native plugin dependency graph.

Account invalidation deliberately disconnects unaffected peers in that account.
The bounded policy table retains tombstones and fails closed at capacity rather
than evicting generations. Transport byte totals include TLS/framing overhead;
live endpoint metrics reset at reconnect, with final metadata usage records
provided for aggregation. Conservative token reservations can overcharge partial
I/O and are traffic ceilings, not billing. The service README contains operator
actions.
