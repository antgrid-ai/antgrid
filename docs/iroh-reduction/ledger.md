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
| A | A4 project streams replace the `{s,m}` mux | done | `3d7ecc53` |
| A | A5 delete credits, schedulers, fragmentation, stream envelope | done | `eb67f79b` |
| A | A6 docs, diagnostics and ledger | done | `4c2f22de` |

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
- A4: wire 138; bridge 4923 pass with the 6 known failures; relay 173; relay_client 306; peer_transport 64; app 4188; `flutter analyze` clean; evals 119 pass, 5 skip, gate-vectors green after the commit; qualify runs and the relay gate pass.
- A6: bridge 4888 pass, 16 skip, 6 fail (the six known stale-runId fixtures), 4910 total, via `bun run --filter antgrid-bridge test`; 4886/4908 before A6, the difference being its two netwatch tests. Only bridge was re-run, since A6 changes no other workspace; A5's own wire/relay/app counts are not recorded here.

### Stage A open items

- **Native soak RSS bound: still fails at `848df2f2`, but no leak was found in the soak's process.** The bound samples `process.memoryUsage().rss` of the `bun test` process. That process holds the in-process relay, each cycle's fake license API (`Bun.serve`) and the eval `RelayClient` with its `@number0/iroh` endpoint. It does not sample the bridge child.
  - *Executed:* the unmodified soak failed at 550s, cycle ~207, with an RSS delta of 135,352,320 bytes against the 134,217,728 bound. Its other assertions passed.
  - *Executed, per-cycle trace with the bound disabled and no forced GC:* the RSS delta grows linearly by about 0.58 MiB per cycle: 14 MiB at cycle 0, 73 at 100, 128 at 200 (536s), and 158 at 251. The JSC heap and object count grow with it (16.8 → 48.7 MiB, 244k → 522k objects), as do `arrayBuffers` (0 → 14.9 MiB). At cycle 252 (682s) the first natural full collection fired. RSS fell from 285 to 172 MiB and objects fell back to 259k. After that the sawtooth stayed at a delta of about 43–51 MiB.
  - *Executed, `Bun.gc(true)` after every cycle:* the RSS delta stayed flat at 11–18 MiB for 340 cycles (900s), and the 15-minute run passed. With a GC every 40 cycles it went up and down between 23 and 37 MiB.
  - The sign therefore says the growth is garbage the collector reclaims, not retained state. The bound trips because JSC's first full GC comes about 150 MiB above the starting RSS. That is a bound/GC-timing problem, and the bound was left unchanged on purpose. The candidates are a `Bun.gc(true)` before the sample, or a slope bound across cycles; the owner decides which.
  - *Executed, heap snapshot at cycle 200 after a forced GC:* the only per-cycle retention is test-side and small. Bun roots one stopped fake-license `DebugHTTPServer` per cycle through its `fetch` closure, together with that cycle's `PeerAuthorizationFixture` (4 Maps, 2 Sets, a Uint8Array, a BigInt) and a settled Promise. Nothing product-side grows: no stream bindings, peer maps, netwatch buffers, record readers or listener arrays. With a GC every cycle this costs about 12 KB per cycle, or about 8 MiB over a 30-minute run.
  - *Executed, standalone probes of 150 iterations each without GC:* bind+close of an Iroh endpoint costs about 21 MiB in total and is not returned by GC; `Bun.serve` start/fetch/stop costs about 8 MiB; a WebSocket round trip about 6 MiB; `Bun.spawn`+kill about 0. None of these alone explains 0.58 MiB per cycle.
  - *Read, not executed:* Stage B removed the eval client's X25519/AES-GCM sealing, which was the main source of JS allocation churn per frame. That fits "less JS pressure, later first full GC", but no run at the pre-Stage-B commit was made to confirm it.
- RPC replies to a relay peer are now addressed to the asking peer instead of broadcast to every peer bound to the project (contract D-10); before A4 the mux stream id scoped them implicitly.
- **Fixed:** the bridge read loops for project streams (`project-streams.ts`) and terminal streams now check `authorized()` per inbound record, same as tunnel streams and the outbound writer.
- **Fixed:** `PeerSessionOwner.sendControlPlane`'s dead `authorized` parameter is removed.
- Under the full `test:evals` sweep, three evals have each failed once and then passed when their file ran alone: the tunnel stream cap, the terminal never-acked viewer cap, and `agent-core-checkout-routing` (known EPERM rename race). `chat-session-codex` auto-title failed in the sweep and alone after A5 with `bridge/src` unchanged from a passing run; probably the real Codex title generation, not proven.
- The native soak was re-run at `848df2f2` (after A5/A6); see the RSS-bound item above.
- **Fixed:** `NetwatchEvent.streamKind`/`streamId` (`bridge/src/netwatch.ts`) are now set at every record/ingest call site in `peer-session-owner.ts`, `project-streams.ts`, `peer/terminal-streams.ts`, `peer/tunnel-streams.ts`, `peer/native-host-connection.ts` and `peer/stream-dispatch.ts` (a `peer:stream-refused` names the stream its open frame named; an open timeout or an unparseable open names none), so a native capture can be filtered by stream. Both stay out of the `joinCaptures` key, since the app's capture has neither field. `streamId` is a display label, not a QUIC stream id: `NETWATCH_SESSION_STREAM_LABEL` (`"0"`) for the session stream and the `projectId` for a project stream, matching the app's own label; the terminal and tunnel labels (the open frame's `requestId`/`wsId`) are bridge-only today, since the app writes neither.

- The bridge and the app can briefly disagree on free slots while a close is in flight, so the bridge may refuse a new stream with `CAP_EXCEEDED`. Accepted.
- A tunnel request body is reassembled in memory before `serveHttp`, so the worst case per peer is the wire body cap times 128 streams.
- The bridge frees a tunnel slot when it unbinds, before the app's FIN, so a misbehaving app can hold QUIC streams past 128; the 256 bidi limit bounds it.
- The tunnel-cap eval opens 128 streams in sequence and takes about 9s, close to other 10s timers.
- The Dart stream WebSocket channel reports its own close as `TunnelWsClosedByPeer`, where the fake reports `TunnelWsClosedLocally`. Cosmetic: the browser close is forwarded the same way.
- The four A2/A3 carry-overs (terminal slot released before drain, promoted core dropping `peerId`, unscoped `abortTunnelStreams`, untested send- and drain-time `authorized()` checks) were fixed in A4.
