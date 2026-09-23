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
| C | W1 web access route | pending | |
| C | W2 bridge pre-filter | pending | |
| C | W3 Aspire cutover | pending | |
| C | W4 relay eval gate | pending | |
| C | W6 deploy | pending | |
| C | W5 delete custom relay | pending | |
| C | W7 docs | pending | |
| B | — | not started | |
| A | — | not started | |
