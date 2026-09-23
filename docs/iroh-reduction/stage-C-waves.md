# Stage C adversarial wave plan: switch to the stock iroh-relay

Method labels: **READ** means I read the code at the cited file:line. **EXECUTED** means I ran a command: only `git grep`, `ls` and `sed`, with no tests and no builds. **INFERRED** means reasoning from code I read. Upstream source is at `C:/Users/Admin/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/iroh-relay-1.2.0` (called `$UP` below).

## 1. Adjudication

### Where the readers disagree

| Point | Verdict | Method and evidence |
|---|---|---|
| Does ESTABLISH_TIMEOUT (30s) bound the access POST? Reader 1 says yes, reader 2 says no. | **Reader 2 is right; the plan is wrong.** | READ `$UP/src/server/http_server.rs:631-655`. The upgraded connection, which includes `relay_connection_handler`, then `accept`, then `authorize_with` at `:878`, runs in a detached `tokio::task::spawn`. READ `:1047`: `clearable_timeout` wraps only `serve_fut`, which is `serve_connection(...).with_upgrades()` (`:1121-1124`). INFERRED: once the 101 response is sent, nothing server-side bounds the access call. The web handler's 2s deadline is the only bound. If web is black-holed at the network level, relay tasks pile up, limited only by `accept_conn_limit` multiplied by time. |
| Is there an existing route-level web test? Reader 1 says none. | **Reader 1 is wrong.** | READ `web/tests/models/peer-authorization.test.ts:9` imports `peerAdmissionRoutes`. `:104-135` is a real-HTTP route test covering HMAC, 413, freshness, unapproved relay and missing secret. It must be deleted together with the route. |
| Does relay-gateway need a code change? | **Only in TLS mode.** | READ `aspire/scripts/relay-gateway.mjs:26`, where `NATIVE_ROUTES` includes `/generate_204`. READ `$UP/src/server.rs:795-827`: with `[tls]`, `/generate_204` is served only on the plain captive-portal listener at `http_bind_addr`. In cleartext mode nothing changes. |
| Where do the loopback checks go (C3)? | **Mostly already true.** | READ `aspire/peer-stack.ts:62` already hard-codes listen `127.0.0.1`. READ `web/src/env.ts:119-130` makes web refuse to boot unless every `http:` origin in `IROH_RELAY_URLS` passes `isLocalRelayHost` (`packages/antgrid-wire/src/peer-authorization.ts:55-73`). What is lost is only the relay's own second check (`iroh-relay/src/config.rs`). Stage C just needs to keep the TOML `http_bind_addr` on loopback. |
| Does C6 lack a relay client once `iroh-relay/` is deleted? Reader 2 says yes. | **Partly wrong.** | READ `bridge/node_modules/@number0/iroh/index.d.ts:107`: `new EndpointAddr(id, relayUrl, addresses)` allows a relay-only dial. `:77-78`: `online()` resolves once a home relay is usable. `:241`: `RelayMode.customFromUrls`. The eval can drive the stock relay with `@number0/iroh`. The part that is lost is `trustedTls`: the pinned bindings trust no private CA (READ `aspire/peer-stack.ts:18-19`), so the gate must use the dev-insecure http relay. |

### Attempts to refute the stage's core premise

1. **Security: revocation.** The premise holds (READ). The lease is re-checked at native accept (`bridge/src/peer/native-host-connection.ts:204-207`). Revocation arrives through `peer-policy-changed`, then `observePolicyGeneration` (`authorization-lease.ts:52-57`), then `recheckAuthorization`, then `retirePeer` (`native-host-connection.ts:278-285`). The outbox is fed by DB triggers on devices, endpoint registrations and oauth_client (READ `web/prisma/migrations/20260914000000_peer_endpoints/migration.sql:27-77`), not only by the relayConfigHash path.

2. **Security: a new amplification vector the plan does not name.**
   - What it is: `acceptPeer` calls `await this.lease.refresh()` before it looks at `connection.remoteId()` (READ `native-host-connection.ts:204-206`). `refresh()` coalesces only concurrent calls (`authorization-lease.ts:62-63`, `:130-131`). Each sequential inbound QUIC handshake therefore costs one web `/account/devices/me/authorization` request, which is a serializable transaction.
   - Why Stage C matters: today the custom relay's per-account registries stop other accounts from reaching a bridge's endpoint ID. After Stage C, any admitted endpoint from any account, and a revoked endpoint that still holds its relay connection, can loop dials against a known bridge endpoint ID. Each dial becomes a web DB transaction.
   - Conclusion (INFERRED): this is worse than the "spam/DoS" the plan accepts. It needs a bridge wave (C-W2 below).

3. **Fail-open configuration.** READ `$UP/src/main.rs:537-549`: a missing config file gives `Config::default()` with `access = Everyone`. `:91` and `:199` have no `deny_unknown_fields`. A typo, a wrong mount, or a root key placed after a `[table]` header silently produces an open relay. The plan never mentions this, so every wave that emits TOML needs a structural test, and the eval needs an "unregistered is denied" assertion.

4. **Ordering: C before B and A.** The premise holds (READ). C touches `packages/antgrid-wire/src/peer-authorization.ts` only. B and A touch `flow.ts`, `frame`, `peer-protocol.ts` and `e2e`. `index.ts:19` uses `export *`, so no index edit is needed. One trap: the existing `gate-iroh-host-authorization.test.ts:12` imports `bridge/src/e2e`, which B deletes. The new relay gate must not copy that import.

5. **The relayConfigHash loop.** READ `web/src/models/peer-authorization.ts:144-149`. Any change to the `relayUrls` array passed into `authorizationSnapshot` bumps the policy generation and writes an outbox row, and the bridge treats that row as a revocation. The access handler must pass the full `deps.env.IROH_RELAY_URLS`, never `[matchedRelay]`. A single-URL test cannot see the difference.

## 2. Plan corrections

| # | Plan text | Correction | Method |
|---|---|---|---|
| 1 | "only the 30s handshake ESTABLISH_TIMEOUT bounds it" (:89-90) | Nothing bounds it once the 101 is sent. The web handler's 2s deadline is the only bound (see §1). | READ + INFERRED |
| 2 | C1 "Run `peerRelayAdmission`" | Its signature uses `PeerRelayAdmissionRequest` / `Response`, which C5 deletes (`web/src/models/peer-authorization.ts:3-7,177-199`). Split out a core function `admitRelayEndpoint(db, endpointId, relayUrl, relayUrls, options): Promise<boolean>`. | READ |
| 3 | C1 secret `IROH_RELAY_ACCESS_TOKEN` | Upstream already uses that name for `access.shared_token` (`$UP/src/main.rs:40,233-236`). Rename the web-side secret (see D3). The relay side reads `IROH_RELAY_HTTP_BEARER_TOKEN` (`main.rs:38,225-228`). | READ |
| 4 | C1 "check it against `IROH_RELAY_URLS`" | Env entries are stored un-normalised, and `https://x` and `https://x/` both pass (`packages/antgrid-wire/src/peer-authorization.ts:69-74` only checks `pathname === "/"`). Today's check is an exact `includes()` (`web/src/models/peer-authorization.ts:180`). Compare `new URL(q).href` against `new URL(u).href`, and still pass the raw env array into the snapshot (see trap §1.5). | READ + INFERRED |
| 5 | C1 "Verify reqwest keeps the query" | Already verified: `IntoUrl for Url` returns self (`reqwest-0.13.5/src/into_url.rs:22-34`), and upstream's own test config carries a query (`main.rs:850`). reqwest follows up to 10 redirects, so the route must never answer 3xx. | READ |
| 6 | C1 "Keep the 32-in-flight 503 bound" | Upstream treats 503 as deny (`main.rs:324-335`). The counter must be decremented when the DB work settles, not when the deadline race settles, because a Promise.race cannot cancel Prisma. | READ + INFERRED |
| 7 | C2 "Remove the target from `PEER_POLICY_TARGETS`" | That value is env config, not code. It lives in `aspire/peer-stack.ts:71-74`, `deploy/iroh/README.md:22-24`, `docs/iroh-operations.md:26`, the fixture `web/tests/models/peer-policy-outbox.test.ts:8`, and live deployment secrets. A stale target wedges the outbox, because a row counts as delivered only if every target succeeds (`web/src/relay/peer-policy-outbox.ts:40`). In production, remove the target before the custom relay is retired. | READ |
| 8 | C3 "the 9090 default collides" | No in-repo collision (EXECUTED grep, per reader 1). The real reason to set it explicitly is that the metrics listener defaults to `[::]:9090` on all interfaces (`main.rs:344-347,379-381`). With `[tls]`, a captive-portal listener always binds `http_bind_addr`, default `[::]:80` (`server.rs:795-810`). | READ |
| 9 | C3 `apphost.ts:153-159,209-213` | The list misses `aspire/peer-stack.ts:52-75` (JSON config writer, `adminSecret`, disconnect target), `apphost.ts:206` (the central relay's `RELAY_INTERNAL_SECRET` comes from `peerStack.admissionSecret`), and `apphost.ts:215-229` (gateway `waitFor(nativeRelay)`). | READ |
| 10 | C4 `monitoring/alerts.yml` | The real path is `deploy/iroh/monitoring/alerts.yml`. Also affected: `prometheus.yml` (target `127.0.0.1:9000`), `grafana-dashboard.json` (antgrid_iroh_* series), `monitoring/README.md`, `deploy/iroh/README.md:7,10,22-24`, `administration.nginx.conf`, and the `.gitignore:128-137` whitelist. A new `relay.example.toml` is silently git-ignored unless it gets a `!` entry. | READ/EXECUTED |
| 11 | C5 `LICENSING.md` | It has no relay entry (EXECUTED grep, reader 1). `THIRD-PARTY.md:27-32` needs rewriting, not deleting: the stock binary is still shipped, MIT OR Apache-2.0 (`$UP/Cargo.toml:31`). | READ |
| 12 | C5 delete list | It misses: the lowercase factory `peerRelayAdmissionRequestSchema` and types (`peer-authorization.ts:95-117`); the wire test `packages/antgrid-wire/src/peer-authorization.test.ts:4-27`; the web route test `web/tests/models/peer-authorization.test.ts:104-135`; the mount at `web/src/app.ts:10,126`; the script `web/package.json:14` (`test:peer-admission`); and `web/CLAUDE.md:19-20`, which must change in the same commit per the root CLAUDE.md rule. | READ/EXECUTED |
| 13 | C6 "bridge retires the peer within 60s" | Already asserted by `evals/tests/gate-iroh-host-authorization.test.ts:149-167`, over direct loopback. The relay gate spawns no bridge today (READ `gate-iroh-relay-authorization.test.ts:16-92`). Adding one duplicates the host gate. See D5. | READ |
| 14 | C7 "root CLAUDE.md mentions" | The root CLAUDE.md has none. Missed files: `web/CLAUDE.md:19-20`, `aspire/README.md:49-57,108-112`, and `docs/iroh-qualification.md:33-34,48-49,115-120`. That last file records the opposite decision ("stock … plus asynchronous disconnect is insufficient"), and the reversal's rationale must be restated there. | EXECUTED/READ |
| 15 | Accepted losses | Add: a bridge-side web-load amplification per foreign or revoked dial (§1.2); unbounded duplicate connections per endpoint (reader 2, `clients.rs` inactive Vec); `antgrid_iroh_backend_ready` and the admission-rejection alerts, which have no upstream equivalent. | READ + INFERRED |

## 3. Wave breakdown

Every commit must leave `bun run aspire` bootable. The plan therefore adds the new path alongside the old one, cuts over, and only then deletes.

```
W1 web route ──┬── W3 aspire cutover ──┐
               ├── W4 eval gate ───────┼── W5 delete ── (W7 docs, parallel with W5)
               └── W6 deploy ──────────┘
W2 bridge accept pre-filter: independent, parallel with everything
```

### C-W1: web access route, added alongside the old one

- **Files owned:**
  - `web/src/routes/iroh-access.ts` (new)
  - `web/src/models/peer-authorization.ts`
  - `web/src/app.ts`
  - `web/src/env.ts`
  - `web/.env.example`
  - `web/tests/routes/iroh-access.test.ts` (new)
  - `web/tests/models/peer-authorization.test.ts`
  - `web/tests/env.test.ts`
  - `web/CLAUDE.md` (add one line about the new route)
- **Symbols:**
  - Extract `admitRelayEndpoint(db, endpointId, relayUrl, relayUrls, options): Promise<boolean>` from `peerRelayAdmission` (`:177-205`). Keep `peerRelayAdmission` as a thin wrapper until W5.
  - The new route `POST /internal/iroh-access`:
    - `Cache-Control: no-store`.
    - Bearer check: compare `timingSafeEqual(sha256(a), sha256(b))` to avoid a length leak. With no configured token, deny every request.
    - Read `X-Iroh-NodeId` and validate it with `EndpointIdSchema`.
    - Validate the `relay` query with `peerAuthorizationSnapshotSchema(dev).shape.relayUrls.element` (as `env.ts:119` does), then match it against `IROH_RELAY_URLS` by normalised href.
    - Pass the raw `deps.env.IROH_RELAY_URLS` into the model.
    - 2s deadline: return `c.text("false")` on timeout. `pending` is decremented in the work promise's `finally`, not the race's.
    - Return 503 when `pending >= 32`.
    - Answer `c.text("true")` or `c.text("false")` with 200. Never `c.json`: JSON `true` happens to equal `"true"` today, but a trailing newline would deny everyone.
  - Env: add the token (D3), `z.string().min(32).optional()`.
- **Tests:**
  - A route test with real Postgres, like the existing pattern.
    - Denials: missing or wrong bearer; a malformed or absent header; a missing, unapproved or non-local http relay query.
    - Allow: the body text is exactly `true`.
    - Relay URL forms: a trailing-slash variant of an approved relay is allowed.
    - Deadline: an injected slow model makes the route answer `false` within about 2s, and the in-flight count stays held until the model settles.
    - Bound: the 33rd concurrent request gets a non-200.
    - No request produces a 3xx.
  - **relayConfigHash regression:** with two configured relays, admitting via relay B then relay A leaves `peerAuthorizationPolicy.generation` unchanged and adds no outbox row.
  - Model tests `:53-101` move to the new function's shape.
  - Env tests for the token.
- **Gate:** `bun run --filter antgrid-web test`, `bun run --filter antgrid-web typecheck`.
- **Traps that compile clean:**
  - Passing `[relay]` to the snapshot. A single-relay test stays green.
  - `c.json(true)` against `c.text("true")`.
  - Decrementing `pending` in the race.
  - Hono or strict routing answering a trailing-slash path with a 3xx.

### C-W2: bridge pre-filter before the lease refresh (can run in parallel)

- **Files owned:** `bridge/src/peer/native-host-connection.ts`, `bridge/tests/native-host-connection.test.ts`.
- **Symbols:** in `acceptPeer` (`:197-207`), check `connection.remoteId()` against `this.lease.current?.peers` before `await this.lease.refresh()`. For an unknown ID, allow at most one refresh-then-recheck per fixed interval (for example 5s). This covers a registration whose outbox push has not arrived yet. Otherwise close with code 3.
- **Tests:**
  - N sequential dials from an unknown endpoint cause at most 1 refresh per window.
  - A just-registered peer is admitted after one refresh.
  - The existing test "native endpoint identity must be present…" (`:73`) stays green.
- **Gate:** `bun run --filter antgrid-bridge test`.
- **Trap:** the refresh-after-identity order must still re-check `generation !== this.admissionGeneration` after the await (`:204`).

### C-W3: Aspire cutover (after W1)

- **Files owned:**
  - `aspire/peer-stack.ts`
  - `aspire/apphost.ts`
  - `aspire/scripts/relay-gateway.mjs`
  - `aspire/scripts/relay-gateway.test.mjs`
  - `aspire/peer-stack.test.ts` (new)
  - `aspire/package.json` (test script)
  - `aspire/README.md`
- **Symbols:**
  - `preparePeerStack` emits TOML:
    - root keys before any table: `http_bind_addr = 127.0.0.1:<port>`, `enable_quic_addr_discovery = false`, `metrics_bind_addr` on loopback on a non-9090 port;
    - `[limits]`;
    - `[access.http]` with a `url` that carries the percent-encoded `?relay=<url>`;
    - in TLS mode, `[tls]` with `cert_mode = "Manual"`, `https_bind_addr = 127.0.0.1:443`, and a non-80 `http_bind_addr`.
  - Generate a random per-run access token and return it. Do not write it into the TOML: it goes into env `IROH_RELAY_HTTP_BEARER_TOKEN`.
  - Drop `adminSecret` and the disconnect entry from `policyTargets`.
  - `apphost.ts`:
    - A one-shot `cargo install iroh-relay --version 1.2.0 --locked --features server --root .tmp/iroh-relay-bin` executable.
    - `nativeRelay` runs the installed binary with `--config-path` and **never `--dev`**, gated by `waitForCompletion(install)`.
    - Web gets the new token env.
    - The central relay's `RELAY_INTERNAL_SECRET` (`:206`) now comes from the web env value, renamed away from `admissionSecret`.
  - Gateway: in TLS mode, route `/generate_204` to the plain port or drop it.
- **Tests:**
  - `peer-stack.test.ts` parses the TOML (Bun's TOML import or a small parser) and asserts:
    - `access.http.url` is present, and no root key appears after the first table;
    - the query round-trips to the exact `url`;
    - the bind addresses are loopback;
    - the token is not in the file.
  - In the gateway test, the 404 probe path `/internal/disconnect` may stay. It is generic.
- **Gate:** `cd aspire && bun run test`, `cd aspire && npm run aspire:build`, `npm run aspire:lint`. Then one manual bring-up with a real app and bridge. EXECUTED check: the web log shows `/internal/iroh-access` answering `true`.
- **Traps:**
  - A missing config path, or a key placed under the wrong table, silently gives an open relay. The TOML test is the only guard.
  - The 443 bind on non-Windows hosts.
  - The `cargo install` "already installed" exit code.

### C-W4: rewrite the relay eval gate (after W1; parallel with W3 and W6)

- **Files owned:** `evals/tests/gate-iroh-relay-authorization.test.ts`, `evals/support/iroh-authorization.ts` (only if a helper is needed), `evals/package.json`.
- **Design:**
  - Resolve the binary from `ANTGRID_IROH_RELAY_BIN`, else `iroh-relay` on PATH. Fail with the install command if absent.
  - Write a temporary TOML: http on `127.0.0.1:<free port>`, `enable_metrics = false`, access URL at the harness origin with the relay query, token in env.
  - Start the harness with `ANTGRID_DEV_INSECURE_RELAY: true` and the token.
  - Use `@number0/iroh` endpoints with `RelayMode.customFromUrls([relay])`. Note that `applyMinimal` is already used at `native-host-connection.ts:126`.
- **Assertions:**
  1. The registered endpoint's `online()` resolves, and the harness saw `true`.
  2. An unregistered endpoint's `online()` does not resolve within a bound, and the harness saw `false`. This is the fail-open detector.
  3. A relay-only `EndpointAddr(id, relayUrl, [])` dial between the two registered endpoints completes, and packets flow.
  4. After the device DELETE, a fresh bind with the revoked key never comes online, and the harness saw `false`.
  5. The 60s bridge retirement is covered by `gate-iroh-host-authorization` (D5).
- **Gate:** `bun run --filter antgrid-evals test:evals:iroh-relay-authorization`. This needs Postgres (`evals/support/iroh-authorization.ts:26-28`) and the binary. Keep the `evals/package.json:7` ignore unless CI installs the binary.
- **Traps:**
  - Do not import `bridge/src/e2e` (Stage B deletes it).
  - On loopback, iroh may upgrade to a direct path. Assertion 3 must check the path is relay (`isRelay`, `index.d.ts:400`) before the upgrade, or rely on the online and deny assertions only.

### C-W5: delete (after W3 and W4)

- **Files owned:**
  - `iroh-relay/**`
  - `.github/workflows/iroh-relay.yml`
  - `web/src/routes/peer-admission.ts`
  - `web/src/app.ts` (the mount)
  - `web/src/models/peer-authorization.ts` (the wrapper and the imports at `:3-7`)
  - `web/tests/models/peer-authorization.test.ts:104-135`
  - `web/package.json:14` (rename to `test:peer-authorization`)
  - `packages/antgrid-wire/src/peer-authorization.ts:95-117`
  - `packages/antgrid-wire/src/peer-authorization.test.ts:4-27`
  - `THIRD-PARTY.md:27-32` (rewrite as "ships stock iroh-relay 1.2.0, MIT OR Apache-2.0")
  - `web/CLAUDE.md:19-20`
- **Gate:**
  - `bun run --filter antgrid-web test`
  - `bun run --filter antgrid-wire test`
  - `bun run --filter antgrid-relay test`
  - `bun run --filter antgrid-bridge test`
  - `cd aspire && bun run test`
  - Grep proof: `git grep -n "peer-admission\|PeerRelayAdmission\|antgrid-iroh-relay\|real_backend_gate"` is empty outside `docs/`.
- **Trap:** `relayUrlsSchema` is not exported. Keep reaching it through `.shape.relayUrls.element`. Do not add a new export to the Apache package for web's convenience.

### C-W6: deploy (after W1; parallel with W3 and W4)

- **Files owned:**
  - `deploy/iroh/compose.yaml`
  - `deploy/iroh/relay.example.toml` (new)
  - `.gitignore:128-137` (whitelist the new file, drop the nginx line)
  - `deploy/iroh/administration.nginx.conf` (delete)
  - `deploy/iroh/monitoring/{alerts.yml, prometheus.yml, grafana-dashboard.json, README.md}`
  - `deploy/iroh/README.md`
- **Content:**
  - The image is pinned by digest. The digest is unverified, and a `cargo install`-based Dockerfile is the fallback.
  - `cert_mode = "Manual"` or `"Reloading"`.
  - Publish 443 and 80 (the captive portal) only. Metrics bind to `127.0.0.1`.
  - The token comes through env.
  - Prometheus scrapes the `relayserver` group.
  - The alerts use `up` plus `/healthz`, and drop the backend-ready and rejection alerts (D6).
  - README runbook order:
    1. Deploy web with W1.
    2. Remove the `/internal/disconnect` target from live `PEER_POLICY_TARGETS`.
    3. Swap the relay container, keeping the same origin.
    4. Retire the custom relay.
- **Gate:** `docker compose -f deploy/iroh/compose.yaml config` if docker is available, then review. No suite covers these files.
- **Trap:** without the `.gitignore` entry the example file is silently absent from the commit.

### C-W7: docs (parallel with W5 and W6)

- **Files owned:** `docs/architecture.md:58-61`, `docs/iroh-operations.md` (`:5,26,28,50,119-120`), `docs/iroh-qualification.md` (`:33-34,48-49,115-120`: restate the reversal).
- **Gate:** link check by grep for `iroh-relay/`.

### Parallelism

- **Parallel:** {W1, W2}, then {W3, W4, W6}, then {W5, W7}.
- **Serial:** W1 before W3, W4 and W6; W3 and W4 before W5. W1 and W5 share `web/*` and `web/CLAUDE.md` and are serialized by that order.
- **No wave spans the bridge and app wire:** the clients need no change (READ `native-host-connection.ts:131-133`; `iroh_peer_link.dart:45-50` dials only).

## 4. Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 (plan Q1) | Relay-origin binding | **Query binding with a normalised compare, one shared token.** The query is configuration, not an authenticated claim. Its real value is decommissioning: removing a relay from `IROH_RELAY_URLS` makes web deny all of that relay's new connections at once. |
| D2 (plan Q2) | Stock relay or thin fork | **Stock.** 1.2.0's library does expose `on_disconnect` and `query_pairs` (`$UP/src/server.rs:234-305`), but using them brings back a Rust crate, its CI and its license inventory, which is what Stage C deletes. Instead, take W2 plus `[limits]`. |
| D3 | Web secret name | Use **`PEER_RELAY_ACCESS_TOKEN`** on web and `IROH_RELAY_HTTP_BEARER_TOKEN` on the relay. Aspire generates it per run, so `scripts/dev-setup.ts` does not change. |
| D4 | Accept the bridge amplification vector, or ship W2 | **Ship W2 inside Stage C.** It is the concrete cost of losing per-account registries. |
| D5 | Should the relay gate also run a bridge and assert 60s retirement? | **No.** `gate-iroh-host-authorization` already asserts it. The relay gate covers only relay admission and denial. The `bothConnectionsClosed` guarantee is dropped for good. |
| D6 | Monitoring loss (`antgrid_iroh_backend_ready`, rejection counters) | Accept it for now, alerting on `up` and `/healthz`. An optional follow-up is a web-side deny/timeout counter or log alert. |
| D7 | Cache denies in the access route (against reconnect loops) | Start with no caching. Add in-flight single-flight per endpointId if load shows it. Never cache an allow: that would delay revocation. |
| D8 | How the stock binary gets onto CI and dev boxes (the digest is unverified) | Pinned `cargo install --locked` for Aspire and evals. For deploy, a two-line Dockerfile around `cargo install` unless the owner confirms an upstream image digest. |
| D9 | Production cutover | Follow the W6 runbook order. The disconnect target must leave live secrets before the custom relay is retired, or the outbox wedges. |