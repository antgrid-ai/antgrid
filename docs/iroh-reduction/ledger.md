# Iroh transport reduction ledger

Status of [../iroh-transport-reduction-plan.md](../iroh-transport-reduction-plan.md).
The per-stage wave plans (`stage-C-waves.md`, `stage-B-waves.md`,
`stage-A-waves.md`) were produced by an adversarial verification of the plan
against the code at `d241d934`. They correct the plan where the two disagree;
the code wins over both.

## Owner decisions (2026-09-23)

| Topic | Decision |
|---|---|
| C: relay origin binding | Query parameter `?relay=<origin>` on the access URL, compared by normalised href against `IROH_RELAY_URLS`; one shared bearer token. Upstream keeps the query (reqwest `IntoUrl for Url`). |
| C: cross-account registry | Stock binary, no fork; tune `[limits]`. The bridge pre-filters unknown endpoint IDs before the lease refresh (C-W2) to bound the web-load amplification. |
| C: web secret name | `PEER_RELAY_ACCESS_TOKEN` on web; the relay reads `IROH_RELAY_HTTP_BEARER_TOKEN`. (`IROH_RELAY_ACCESS_TOKEN` is upstream's `shared_token` variable.) |
| C: relay gate scope | Admission and denial only; 60s bridge retirement stays covered by `gate-iroh-host-authorization`. |
| B+A packaging | One released frame version for B and A. Both land on the branch, gated per wave; wire v4 is never released alone. |
| B: hello shape | `session:hello {attemptId, capabilities}` → `established {attemptId}`; one session per connection; re-hello with a new attemptId closes. |
| B: same-endpoint reconnect | Newest authenticated connection wins in `acceptPeer`. |
| B: pre-establishment frames | Dropped per peer, fail closed; control-plane gate becomes per-peer. |
| B: app dispatch | Synchronous in-order inbound dispatch replaces `_inboundTails` (Stage A prerequisite). |
| A: scope | Descoped: terminals and tunnel HTTP/WS get their own streams, project streams replace the mux; file:read, diffs, search, tree snapshot and upload stay on the project stream. |
| A: loopback | No loopback wire change; the `channel` label and preview-channel classification stay, loopback-only. |
| A: refusals | In-band `stream:refused` records (Dart cannot read reset codes); overflow resets the one stream, never the connection. |
| A: version | `FRAME_VERSION` stays at the value Stage B set, since that value was never released. A1 bumps the ALPN to `antgrid/peer/2`. |
| A: caps | Accepted by the owner on 2026-09-24. On the bridge: QUIC bidi limit 256 per connection. Per peer: projects 32, terminal attachments 64, tunnel streams 128, pending opens 16. The app mirrors these with semaphores. |

## Status

| Stage | Wave | Status | Commit |
|---|---|---|---|
| C | W1 web access route (`POST /internal/iroh-access`) | done | `6f579acc` |
| C | W2 bridge pre-filter before the lease refresh | done | `e5da9b24` |
| C | W7 docs | done | `9b35ead2` |
| C | W6 deploy (cargo-install Dockerfile, TOML, monitoring) | done | `10bc9245` |
| C | W3 Aspire cutover | done | `8b9647a3` |
| C | W4 relay eval gate (stock binary) | done | `0468789c` |
| C | W5 delete custom relay and admission route | done | `d5e33177` |
| C | follow-up: relay URL schema threw on unparseable input | done | see git log |
| B | W0a move `rawSeedToPkcs8` out of `e2e/` | done | `0f4a18e4` |
| B | W0b netwatch joiner pairs by occurrence, direction and channel | done | `be318d75` |
| B | W0c one bridge test session-establish seam | done | `6fdd0d3f` |
| B | W0d delete the peer-restart rekey trigger | done | `dfcd78f7` |
| B | W0e remove the app pin path (D8) | done | `ce336965` |
| B | W1 flip: plaintext hello, app-layer sealing removed | done | `f487a670` |
| B | W2a drop the native CNG AES-GCM cipher | done | `e0666f12` |
| B | W2b delete bridge `e2e/` and trusted-peers | done | `ee344c45` |
| B | W2c delete Dart E2E crypto and the vector fixture | done | `a7684de7` |
| B | W3 docs and CLAUDE.md rules | done | `0eec4443` |
| B | follow-up: evals typecheck, stale public crypto claims, uncalled `hasEstablishedSession` | done | see git log |
| A | A0a bridge per-stream record I/O | done | `a6e8ca51` |
| A | A0b stream-open wire schema and refusal codes | done | `a1e9284f` |
| A | A0c Dart multi-stream peer link | done | `fb396bb0` |
| A | A0d app hazards B and C (terminal drain, history boundary) | done | `7c97b72c` |
| A | A1 multi-stream admission, ALPN `antgrid/peer/2` | done | `7523c75a` |
| A | A2 terminal attachment streams | done | `8a13d83b` |
| A | A3 tunnel HTTP/WS streams | done | `55c741e8` |
| A | A4 project streams, A5 deletions, A6 docs | not started | |

### Stage C gate evidence (executed by the wave commit agents)

- web 671 pass; wire 111 pass; relay 173 pass; aspire 6 pass, 1 skip (TLS gateway test needs `TEST_TLS_CERT`/`TEST_TLS_KEY`).
- Bridge 4841 pass, 6 fail: all six are hook/session-title/notify tests, the known runId fixture drift, not in files Stage C touched.
- The relay gate (`ANTGRID_IROH_RELAY_BIN=.tmp/iroh-relay-bin/bin/iroh-relay.exe bun run --filter antgrid-evals test:evals:iroh-relay-authorization`) passes. Replacing the access config with `access = "everyone"` makes it fail, so the gate does catch a relay that admits everyone.
- The generated Aspire TOML and `deploy/iroh/relay.example.toml` both load in the real binary; `/healthz` and `/metrics` answer.

### Stage C open items

- **Not done:** the live bring-up with a real app ↔ bridge connection forced through the stock relay. Only relay admission has been exercised end to end, through the eval gate.
- `npm run aspire:lint` fails. The cause is pre-existing: no `aspire/eslint.config.*` has ever existed.
- The Docker image has not been built because the daemon is down. Its base-image digests are reused from the fork's Dockerfile and were not re-reviewed.
- Upstream prints the whole config, bearer token included, at `RUST_LOG=debug`. This is documented in `deploy/iroh/README.md`.
- A misspelt non-access TOML key is silently ignored upstream. The guards catch only a missing file or a missing `[access.http]`.
- The `[limits]` values (accept 32/s, burst 64; rx 10 MiB/s, burst 2 MiB) were accepted by the owner on 2026-09-24.
- The W2 throttle stamp survives a failed refresh, so a new device that hits a transient web error is refused for up to 5s. Accepted as minor.
- Production cutover order is in `deploy/iroh/README.md`. The `/internal/disconnect` target must leave the live `PEER_POLICY_TARGETS` before the custom relay is retired, or the outbox wedges.

### Stage B gate evidence (executed)

- W1, by the flip integrator: wire 110, relay 173, relay_client 267, peer_transport 29, app 4215 pass; bridge 4842 pass with the 6 known failures; `qualify:iroh-host` and `qualify:iroh-interop` pass.
- `flutter analyze`: after the stage it found one info in a W0e test. That is fixed, and now `app` and all three Dart packages report no issues.
- Evals: the count fell from 100 to 92 because handshake-only tests were deleted by design. `gate-vectors` is green once the regenerated fixture is committed.

### Stage B open items

- `site/src/pages/privacy.md` still claims X25519 + AES-256-GCM app-layer encryption. It is a legal page, so the owner has to reword it; nothing else public still makes that claim.
- `app/build/windows` must be deleted before the next Windows build anywhere, because W2a removed `cryptography_flutter` from the plugin set.
- The eval client has no `dart test` suite. The evals cover it through `evals/helpers/dart-app-client.ts`.
- `iroh-interop-smoke.ts` and `gate-iroh-host-authorization` still label their pass line `e2e: "real"`, meaning a real session end to end. The label is cosmetic.

### Stage A gate evidence (executed by the wave commit agents)

- A2: wire 130; bridge 4902 pass with the 6 known failures; relay 173; relay_client 283; peer_transport 64; app 4210; `flutter analyze` clean in app and the three packages; evals 108 pass, 5 skip, with the only failure the gate-vectors git-clean guard, which clears at the commit; `test:evals:dart-terminal` 7 pass; qualify runs and the relay gate pass.
- A3: wire 136; bridge 4928 pass with the 6 known failures; relay 173; relay_client 308; peer_transport 64; app 4187; `flutter analyze` clean; evals 113 pass, 5 skip, with the same git-clean guard as the only failure before the commit; qualify runs and the relay gate pass.

### Stage A open items

- The bridge and the app can briefly disagree on free slots while a close is in flight, so the bridge may refuse a new stream with `CAP_EXCEEDED`. Accepted.
- A tunnel request body is reassembled in memory before `serveHttp`, so the worst case per peer is the wire body cap times 128 streams.
- The bridge frees a tunnel slot when it unbinds, before the app's FIN, so a misbehaving app can hold QUIC streams past 128; the 256 bidi limit bounds it.
- The tunnel-cap eval opens 128 streams in sequence and takes about 9s, close to other 10s timers.
- The Dart stream WebSocket channel reports its own close as `TunnelWsClosedByPeer`, where the fake reports `TunnelWsClosedLocally`. Cosmetic: the browser close is forwarded the same way.
- Carried into A4: the app's terminal attachment releases its slot before the records drain; the promoted local core drops `peerId`; `abortTunnelStreams` is not scoped to the peer that changed; the send-time and drain-time `authorized()` checks have no test of their own.
