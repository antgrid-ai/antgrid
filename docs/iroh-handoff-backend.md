# Iroh backend handoff

Implemented 2026-09-14. Additive backend support is ready for integration review;
Iroh transport and relay qualification are separate gates. No deployment or
production configuration was changed.

## Behavior

The strict device bearer middleware resolves `azp` to the active OAuth client and
device, checking token identity, metadata, key, audience and grant type. The
shared `parseDeviceOAuthMetadata` accepts Better Auth's serialized JSON metadata
and validates its decoded fields; malformed values remain denied. The
enrollment model repeats those checks inside a serializable transaction and
rejects missing users or tombstoned owned accounts.

`POST /account/devices/me/endpoint-challenge` accepts the shared endpoint ID and
expected decimal generation. It returns a cryptographically random challenge
with a two-minute expiry. A new challenge replaces that enrollment's previous
challenge; issuance also removes expired challenges.

`POST /account/devices/me/endpoint-registration` verifies both Ed25519 signatures
over `endpointChallengeBytes`. Challenge consumption, prior endpoint revocation,
new registration and policy/outbox invalidation commit atomically. Serializable
conflicts retry; stale generation and replay fail. The endpoint ID primary key
is retained across revocation and credential deletion, preventing reuse by any
registration. SQL enforces one active endpoint per enrollment and unique
enrollment/generation pairs. History deliberately has no cascading credential
foreign key.

`GET /account/devices/me/authorization` returns the authoritative active
subscription decision, bounded lease, current endpoint, highest historical
`registrationGeneration` (including revoked history), policy generation,
eligible opposite-kind devices with active matching OAuth metadata, and explicitly
configured HTTPS relay origins. App snapshots include only machines advertising
remote access. Absence of endpoint enrollment preserves legacy peers as nullable
endpoint entries. No new paid gate was introduced: existing active subscription
resolution includes free subscriptions. Billing account tombstones deny access.
The lease is additionally bounded by subscription cancellation/trial/period end.

Agent/app inventories expose optional `endpoint` and
`transportCapabilities: { iroh: true }` only for enrolled endpoints. These hints
do not replace fresh authorization. Route bodies are bounded, requests are
rate-limited, and responses disable caching.

## Policy invalidation and delivery

Database triggers invalidate policy transactionally for device admission,
revocation, identity, OAuth binding, kind and remote-access changes; endpoint
changes; OAuth credential deletion and authentication-field changes; subscription,
membership and billing-account changes; and user billing-account changes/deletion.
Credential changes revoke endpoint registrations. Heartbeat timestamp-only
updates do not invalidate policy. Billing changes conservatively invalidate all
known transport policies, including upgraded WebSocket devices without endpoint
enrollment. This favors correctness but needs load qualification before rollout.

The snapshot persists a hash of its configured relay list and advances policy
when that configuration changes. Configuration changes are observed at the next
snapshot; operators needing immediate invalidation must trigger it when changing
configuration. Natural subscription expiry is enforced by snapshot lease bounds,
not a wall-clock database trigger.

`PeerAuthorizationOutbox` stores `id`, `userId`, bigint `generation`, `createdAt`,
nullable `deliveredAt`, `attempts`, and `nextAttemptAt`. The process-start worker
uses a transaction advisory lock shared by web replicas, bounded batches and
bounded fanout. It sends `{userId,generation,issuedAt}` with an SHA-256 HMAC in
`x-antgrid-signature`, a two-second timeout and redirect rejection. Every configured
target must acknowledge with 2xx before a row is delivered. Failures retain the
row with exponential retry up to one minute. Delivery is at least once; receivers
must generation-fence duplicate/stale notifications. Logs contain counts only.

## Operator configuration

- `IROH_RELAY_URLS`: comma-separated approved HTTPS origins with no userinfo,
  query, fragment or non-root path. Empty by default; no implicit public relays.
- `PEER_POLICY_TARGETS`: private JSON array of `{ "url": "...", "secret": "..." }`.
  URLs include the complete internal endpoint path. Configure every central
  `/internal/peer-policy` receiver and every deployed Iroh `/internal/disconnect`
  receiver. Secrets are backend-only, never returned in snapshots. Use private
  network administration endpoints; HTTP is supported for the existing private
  central service network, HTTPS for encrypted administration links.
- With no central `/internal/peer-policy` target, the worker leaves rows pending.
  Merely configuring public relay discovery does not configure administration.
  Iroh administration remains unqualified until the relay service exists.

Apply the additive migration through the normal operator deployment. Inspect
pending rows with `SELECT count(*), min(created_at) FROM peer_authorization_outbox
WHERE delivered_at IS NULL`. Investigate failures without printing target secrets.
Do not mark rows delivered manually to silence a backlog. Endpoint history must
remain retained across rollback. A retention policy for acknowledged outbox rows,
outbox dashboards, and billing invalidation load qualification are outstanding.

## Files

- `web/prisma/schema.prisma` and `web/prisma/migrations/20260914000000_peer_endpoints/migration.sql`
- `web/src/models/peer-authorization.ts`, `web/src/routes/peer-authorization.ts`
- `web/src/relay/peer-policy-outbox.ts`, `web/src/index.ts`
- `web/src/app.ts`, `web/src/env.ts`, `web/src/routes/agents.ts`, `web/CLAUDE.md`
- `web/tests/models/peer-authorization.test.ts`, `web/tests/models/peer-policy-outbox.test.ts`
- `web/tests/env.test.ts`, `web/tests/helpers/pg.ts`
- Parent-authored `web/src/auth/jwt-bearer.ts`, `web/src/auth/middleware.ts` and
  `web/tests/routes/device-bearer.test.ts` were preserved; the test mock received
  the required `unknown` intermediate cast for TypeScript.

No root dependency lockfile changed. Prisma-generated code remains generated.

## Verification

- `bun run --filter antgrid-web test`: **645 passed, 0 failed**, including Prisma
  generation, Vite build and ephemeral database migrations; this was before the
  final outbox/configuration-hash additions.
- Final `npm run test -- tests/models/peer-authorization.test.ts
  tests/models/peer-policy-outbox.test.ts tests/routes/device-bearer.test.ts
  tests/env.test.ts` from `web/`: **31 passed, 0 failed, 95 assertions**, including final migration,
  Prisma generation and Vite build. Covers mounted route error/auth behavior,
  signatures, replay/concurrent consumption, rotation/history, stale generation,
  credential denial, nullable legacy peers, entitlement and remote-access changes,
  relay configuration generations, signed outbox fanout, retries and concurrent
  workers.
- Final `bun run --filter antgrid-web typecheck`: **passed**.
- `bun run --filter antgrid-evals test:evals:iroh-authorization`: **1 passed,
  0 failed, 25 assertions** against real HTTP device registration, Better Auth
  token issuance and strict enrollment routes backed by ephemeral PostgreSQL.
  This detected and verified the serialized OAuth metadata correction. See
  `iroh-integration-review.md` for coverage and the separate native-test boundary.
- Restricted `bunx` initially failed writing its temp directory. Direct installed
  Prisma CLI generation succeeded; test execution was subsequently authorized
  with local Postgres access. No secrets were printed.
- Bun forwards filtered test arguments to `pretest`, making Vite interpret the
  test path as its entry root. The initial filtered Bun command's tests passed
  but its pretest failed; the final npm invocation avoids that forwarding and
  passed both phases.

The combined `test:evals:iroh-host-authorization` evaluation now verifies actual
HTTP enrollment through production HostServer native E2E payloads across two
projects during central outage; backend device revocation closes the connection
on the production periodic refresh within the lease bound. See the independent
integration review for exact fixture boundaries and results.

No staging relay delivery, real multi-process public-network revocation,
transport switching or native Iroh physical-platform test is claimed here.
The full final integration gate remains parent-owned.
