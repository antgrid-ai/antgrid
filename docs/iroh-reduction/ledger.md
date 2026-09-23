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
| B | — | not started | |
| A | — | not started | |

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
- The `[limits]` values are placeholders the implementer picked (accept 32/s, burst 64; rx 10 MiB/s, burst 2 MiB). They need an owner call.
- The W2 throttle stamp survives a failed refresh, so a new device that hits a transient web error is refused for up to 5s. Accepted as minor.
- Production cutover order is in `deploy/iroh/README.md`. The `/internal/disconnect` target must leave the live `PEER_POLICY_TARGETS` before the custom relay is retired, or the outbox wedges.
