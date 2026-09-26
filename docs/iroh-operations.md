# Iroh staging and operations

Release status: **unqualified**. Remote payloads require Iroh; the central
WebSocket remains for control only. Relay traffic runs through the stock
upstream `iroh-relay` 1.2.0 binary, admission-gated by web's `access.http`
check. Its unconfigured default is `access = Everyone`, and a missing config
file or a key under the wrong TOML table silently falls back to it, so an
allow-all stock relay does not satisfy this deployment contract. The relay
admission/denial gate is `test:evals:iroh-relay-authorization` (`evals/package.json`) and
has no recorded stock-relay run yet; deployment and native
forced-relay/platform/performance gates remain open.

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
  Include each central relay's full `/internal/peer-policy` URL. The stock
  relay has no admin/disconnect API, so there is no relay-side target: the
  central relay's `peer-policy-changed` push to the bridge is the only
  immediate revocation path, and the bridge's lease is the backstop. A leftover
  `/internal/disconnect` target never succeeds and wedges the outbox.
  Supply secrets through the deployment secret store. They never reach clients.
- `PEER_RELAY_ACCESS_TOKEN`: the bearer token the relay's `access.http`
  presents to `POST /internal/iroh-access`; the relay side reads the same
  value as its own `IROH_RELAY_HTTP_BEARER_TOKEN`. Compared in constant time;
  an unset token denies every request. The route also enforces a 2s deadline
  and a 32-in-flight bound, because nothing on the relay side bounds the
  request once its own upgrade response has gone out.
- `RELAY_INTERNAL_SECRET`: unrelated to Iroh admission — authenticates the
  central control relay's own calls to web (`relay/src/config.ts`).

The outbox remains pending if no central policy target is configured. A batch is
marked delivered only after every configured target returns success. Requests
carry `{userId, generation, issuedAt}`, signed with HMAC-SHA256 in
`x-antgrid-signature`. Central relay administration rejects requests more than
30 seconds old. The worker bounds fanout, times requests out after two seconds,
and retries failures with bounded backoff. Retrying an event cannot renew a
client authorization lease; only an authenticated snapshot can do that.

Do not configure an Iroh URL until its admission and resource limits pass
qualification. URL changes advance policy on the next authorization
snapshot; coordinated immediate invalidation across processes is still an
operator/qualification gap. Delivered-outbox retention remains to be implemented; the supplied monitoring
configuration still needs deployment and load qualification.

## Staging checks

The relay is the stock `iroh-relay` 1.2.0 binary, installed rather than built
from source; `deploy/iroh/relay.example.toml` configures it and `deploy/iroh/`
supplies Compose/private-proxy integration. Prometheus scraping, alert rules
and an importable Grafana dashboard are in `deploy/iroh/monitoring/`,
rewritten onto upstream's own metric names. Their JSON/YAML syntax is checked;
deployment, `promtool` validation and live dashboard queries remain staging
work.

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

## Lifecycle and interrupted-command handling

Native shutdown first fences generations, dispatch, timers, and queued work.
Graceful teardown has five seconds, followed by forced carrier closure and five
seconds for ownership confirmation. A `cleanupIncomplete` result means the
runtime still owns work or a carrier; keep the identity locked and do not start
a replacement. Repeated stop calls share the same completion.

An interrupted mutating request has three local outcomes: `notSent`,
`confirmed`, or `outcomeUnknown`. A completed socket write is not execution
confirmation. After `outcomeUnknown`, refresh authoritative state with reads
and require a fresh user action before submitting another mutation. Never
replay terminal input, reconnect hydration mutations, or host-restart recovery
mutations automatically.

Authorization refresh starts after roughly one third of the accepted lease,
with jitter. Each request is bounded by ten seconds or the remaining lease,
whichever is shorter. Backend failure, central reconnect, and native success do
not move the original deadline. Denial, revocation, rotation, remote-access-off,
or expiry fence dispatch immediately.

Backend registration and lease code is not evidence that a deployed relay
enforces admission. That needs the relay gate run against the deployed
configuration, including an unregistered endpoint being denied, before staging
preference can pass.

## Local evidence commands

Run from the repository root unless a directory is named. Dart/Flutter commands
must run serially; never run bare root `bun test`.

```powershell
bun run --filter antgrid-wire test
bun run --filter antgrid-relay test
bun run --filter antgrid-web test
bun run --filter antgrid-bridge test
bun run --filter antgrid-evals test:evals
bun run --filter antgrid-evals test:evals:native-soak
```

The default serialized eval sweep excludes gates that require a separately
installed native binary. Resolve the stock relay from
`ANTGRID_IROH_RELAY_BIN`, or `iroh-relay` on `PATH`
(`cargo install iroh-relay --version 1.2.0 --locked --features server`), then
run `bun run --filter antgrid-evals test:evals:iroh-relay-authorization`.
Set `IROH_INTEROP_NATIVE_LIBRARY` to the verified Dart native library before
running `test:evals:dart-client-e2e` and `test:evals:peer-resume`.
Backend gates also require the existing PostgreSQL/Prisma test prerequisites.

In `packages/antgrid_peer_transport`, run `dart analyze`, `dart test`, and the
explicit record-only `dart run bin/native_smoke.dart`. Configure the upstream
signed native DLL through `iroh_quic:setup` or the verified prototype cache.
Never use `--no-verify`. The native smoke uses synthetic admission and validates
the production record adapter, shared endpoint cleanup and rejection paths; it
does not qualify backend authorization, real host features, WAN or performance.
The same package supplies app and CLI native code; FRB disposal in the smoke
executable occurs only at process-final teardown.

The native soak is intentionally excluded from the default eval sweep. It runs
for 30 minutes unless its documented test-only duration override is set, records
its seed, and must settle owned-resource counts after every fault cycle.

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
Run a matched workload with fixed sample sizes, including forced relay, blocked UDP, WAN, mobile resume and reconnect storms.

Promote only after security/platform/performance gates pass: internal, 1%, 10%,
50%, 100%, at least 48 healthy hours each. No production deployment is
authorized by this document. There is no WebSocket payload preference switch.
Rollback requires redeploying a previously qualified compatible client/bridge
release; retain additive database fields/history and never replay commands.
Central WebSocket control remains.
