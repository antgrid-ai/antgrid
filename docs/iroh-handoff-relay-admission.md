# Relay admission backend handoff

Implemented `POST /internal/peer-admission`, mounted in the production web app.

The service authenticates the exact request bytes using HMAC-SHA256 and the existing `RELAY_INTERNAL_SECRET`; the lowercase hexadecimal signature is in `x-antgrid-signature`. Missing configuration, missing signature, malformed signature and mismatched signature fail closed. The body is limited to 4096 bytes, strictly parsed against `PeerRelayAdmissionRequestSchema`, and `issuedAt` must be within 30 seconds in either direction. Every route response carries `Cache-Control: no-store`.

Valid, authenticated requests return the shared discriminated response. Denial is `{allowed:false,requestId}`; admission includes endpoint, user, device, enrollment, decimal registration/policy generations and a positive lease no longer than 60 seconds or the subscription deadline. Unapproved relay URLs, inactive endpoints, stale enrollment generations, revoked devices, missing/disabled/misbound OAuth credentials, missing entitlement and deleted accounts deny admission. The registration, identity, entitlement and policy are read in one serializable transaction through the same authoritative logic as device leases.

Authentication errors return 401, schema/JSON errors 400, oversized bodies 413, and database failure or exhausted concurrent-work capacity returns a correlated denial with 503. Concurrent database admissions are bounded per process; the relay retains its own stricter two-second request deadline and fail-closed behavior. The request ID is correlation, not a one-use grant; a repeated still-fresh signed request is evaluated against current database state.

Changed files: `web/src/routes/peer-admission.ts`, `web/src/models/peer-authorization.ts`, `web/src/app.ts`, `web/tests/models/peer-authorization.test.ts`, `web/package.json`, `web/CLAUDE.md`, and this handoff. No Prisma schema, root lockfile, shared schema, Rust or Dart changes were made by this assignment.

## Verification

- `bun run --filter antgrid-web test:peer-admission`: **16 passed, 0 failed, 69 expectations**. Includes Prisma generation and the Vite asset pretest, real ephemeral PostgreSQL transactions and a real loopback HTTP server hosting the production app router. Covers rotation/history, policy generations, credential impersonation/disable, entitlement/account deletion, exact-byte signatures, freshness, unapproved relays, body limit and missing service secret.
- `bun run --filter antgrid-web typecheck`: passed.
- Initial targeted `test <file>` execution revealed Bun forwarding the file argument into the Vite pretest; the bounded workspace script runs pretest separately to avoid that. A sandbox temporary-cache write failure required the approved escalated workspace test invocation. The final command, including pretest, passed.

## Remaining qualification

This backend does not itself prove an upstream relay accepted the decision or disconnected a revoked endpoint. Relay-side authenticated endpoint admission, request-start lease bounds, generation-fenced races, active revalidation/disconnect, traffic accounting and real deployment qualification belong to the relay service gate. DNS, secrets and deployment remain operator actions. The backend never treats missing relay capabilities as authorization to bypass them.
