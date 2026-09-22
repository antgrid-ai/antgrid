# Iroh staging and operations

Release status: **unqualified**. Remote payloads require Iroh; the central
WebSocket remains for control only. The authenticated
self-hosted Iroh relay service under `iroh-relay/` is being integrated using
upstream public APIs. Admission, revocation fencing and resource controls passed
local gates documented in [qualification](iroh-qualification.md);
deployment and native forced-relay/platform/performance gates remain open.
A stock allow-all relay does not satisfy this deployment contract.

## Additive backend deployment

Build the existing `web/Dockerfile` and `relay/Dockerfile`. Apply committed Prisma
migrations with `bun run --filter antgrid-web prisma:migrate:deploy` against the
operator-selected staging database. Deploy central relay support before enabling
outbox delivery. Use the existing authenticated internal network for web-to-relay
calls; do not expose administration paths to client traffic.

The web environment accepts:

- `IROH_RELAY_URLS`: comma-separated approved HTTPS relay origins. Empty means
  no Iroh relays are approved. These public origins appear in authenticated
  device snapshots; they contain no shared secret.
- `PEER_POLICY_TARGETS`: JSON array of private `{url, secret}` delivery targets.
  Include each central relay's full `/internal/peer-policy` URL and, once a
  qualified Iroh service exists, every instance's `/internal/disconnect` URL.
  Supply secrets through the deployment secret store. They never reach clients.
- `RELAY_INTERNAL_SECRET`: authenticates the private `/internal/peer-admission`
  API. Configure the same secret in the Iroh service's `admissionSecret` field.
  The relay signs exact request bytes and bounds the complete request to two
  seconds; backend decisions bind endpoint, relay origin and request ID.

The outbox remains pending if no central policy target is configured. A batch is
marked delivered only after every configured target returns success. Requests
carry `{userId, generation, issuedAt}`, signed with HMAC-SHA256 in
`x-antgrid-signature`. Central relay administration rejects requests more than
30 seconds old. The worker bounds fanout, times requests out after two seconds,
and retries failures with bounded backoff. Retrying an event cannot renew a
client authorization lease; only an authenticated snapshot can do that.

Do not configure an Iroh URL until its admission, active disconnect and resource
limits pass qualification. URL changes advance policy on the next authorization
snapshot; coordinated immediate invalidation across processes is still an
operator/qualification gap. Delivered-outbox retention remains to be implemented; the supplied monitoring
configuration still needs deployment and load qualification.

## Staging checks

The relay's build, configuration and private administration instructions live
under `iroh-relay/`; `deploy/iroh/` supplies Compose/private-proxy integration.
Prometheus scraping, alert rules and an importable Grafana
dashboard are in `deploy/iroh/monitoring/`. Their JSON/YAML syntax is checked;
deployment, `promtool` validation and live dashboard queries remain staging work.

1. Verify central `/health`, web health, migrations and policy worker logs.
2. Provision distinct bridge and controller devices. Use their OAuth bearer
   credentials for `/account/devices/me/authorization`; a cookie alone must fail.
3. Register endpoints with `/endpoint-challenge` and `/endpoint-registration`
   under that prefix. Both keys sign the exact transcript defined in
   `packages/antgrid-wire/src/peer-authorization.ts`. Replay, stale rotation,
   another device's credential and endpoint reuse must fail.
4. Check the snapshot's `registrationGeneration`, `policyGeneration`, eligible
   peers and approved relays. Generations are decimal strings, including above
   JavaScript's safe integer range. Never renew from cached inventory.
5. Change remote access, revoke a device and change entitlement. Observe pending
   outbox delivery, account-scoped policy events, immediate dispatch blocking
   and native disconnect. Repeat with one administration target unavailable;
   the outbox must retry and the unchanged lease deadline must stop traffic.
6. Exercise a central outage with healthy native peers, then restore central
   service. Check project bindings, terminal continuity, no duplicate writers,
   and no command replay. Genuine peer failure requires fresh E2E/hydration.
7. Force an epoch replacement. The superseded central socket must stop retrying,
   expose a control conflict, and leave healthy leased native sessions intact.
   Only an explicit Retry may clear the conflict and reconnect control.
8. Send a binary frame and each retired stream-registration verb after central
   authentication. Each must receive PROTOCOL_VIOLATION and close code 1008.

Backend registration and lease code is not evidence that an upstream relay has
enforced admission. The latter needs independent service race tests before
staging preference can pass.

## Local evidence commands

Run from the repository root unless a directory is named. Dart/Flutter commands
must run serially; never run bare root `bun test`.

```powershell
bun run --filter antgrid-wire test
bun run --filter antgrid-relay test
bun run --filter antgrid-web test
bun run --filter antgrid-bridge test
bun run --filter antgrid-evals test:evals
```

Before the full eval sweep, build its Rust relay probe with
`cargo build --locked -j 2 --manifest-path iroh-relay/Cargo.toml --example real_backend_gate`.
Run just the combined backend/relay gate with
`bun run --filter antgrid-evals test:evals:iroh-relay-authorization`.
Backend gates also require the existing PostgreSQL/Prisma test prerequisites.

In `packages/antgrid_peer_transport`, run `dart analyze`, `dart test`, and the
explicit record-only `dart run bin/native_smoke.dart`. Configure the upstream
signed native DLL through `iroh_quic:setup` or the verified prototype cache.
Never use `--no-verify`. The native smoke uses synthetic admission and validates
the production record adapter, shared endpoint cleanup and rejection paths; it
does not qualify backend authorization, real host features, WAN or performance.
The same package supplies app and CLI native code; FRB disposal in the smoke
executable occurs only at process-final teardown.

## Platform and rollout gates

macOS artifacts and updater feed are now Apple Silicon specific:
`antgrid-macos-arm64.dmg` and `appcast-macos-arm64.xml`. No Intel build or
transitional universal release is planned. Signing/notarization remains in the
desktop build workflow. macOS, Linux and physical mobile packaging must be
verified on their actual runners/devices; Windows smoke does not cover them.

Collect payload-free connection-stage timings, native connection failure
reason, direct/relay bytes, CPU and memory. Native path telemetry is currently
conservative (`unknown` where bindings do not provide a verified classification).
No dashboard may turn missing samples into zero latency or zero server bytes.
Run the matched workload and sample sizes in [the plan](iroh-migration-plan.md),
including forced relay, blocked UDP, WAN, mobile resume and reconnect storms.

Promote only after security/platform/performance gates pass: internal, 1%, 10%,
50%, 100%, at least 48 healthy hours each. No production deployment is
authorized by this document. There is no WebSocket payload preference switch.
Rollback requires redeploying a previously qualified compatible client/bridge
release; retain additive database fields/history and never replay commands.
Central WebSocket control remains.
