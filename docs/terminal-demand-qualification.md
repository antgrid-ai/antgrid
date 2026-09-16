# Terminal demand qualification — 2026-09-12

The app implementation is shared by local and relay connections. Release
qualification remains incomplete for the reasons below. No transport or wire
protocol changes are included.

## Automated coverage

`app/test/services/terminal_demand_test.dart` exercises discovery without demand,
shared pane ownership, readiness and input gating, sequential prefetch,
cancellation before acceptance, promotion, late frames, cached refresh, timeout,
hidden notification badges, respawn invalidation, pending exit settlement,
confirmed hidden-agent handoffs, and canceled-resize geometry invalidation.
`terminal_screen_cache_test.dart` exercises global count/byte eviction.
Existing frame, reattachment, history, resize, and input suites now explicitly
register their displayed terminals.

`app/test/widgets/terminal_display_visibility_test.dart` exercises overlapping
agent/pinned panes, hidden mounted children, page visibility changes, cached
screen restoration, and refresh input gating. The existing native scrollback
widget suite still covers history focus, touch IME, keyboard actions, uploads,
selection, and returning to live output.

File-service tests cover activation without a tree request, multiple consumers,
last-consumer release, reconnect, unchanged revisions, and deferred sequence-gap
recovery. Files and composer mentions acquire demand through `TreeInterest`.

Validation commands:

```sh
cd app
flutter test --no-pub -j 2
flutter analyze --no-pub
cd ..
npm run check:font-tokens
bun run --filter antgrid-bridge test tests/terminal-frame-delivery.test.ts tests/terminal-frame-cancellation.test.ts tests/terminal-frame-final-screen.test.ts
bun run --filter antgrid-evals test:evals:terminal-frames
bun run --filter antgrid-bridge qualify:terminal-frames --phase performance --output ../.tmp/terminal-demand-qualification
```

The final review-fix Flutter suite passed (3,866 tests, two skips), including
the file-tree lifecycle regressions. The focused review regression run passed
53 tests. Flutter analysis and the design font-token check passed.

The focused bridge delivery gate passed (41 tests). The explicit E2E gate passed
all 13 cases, including local and relay delivery, unsubscribe settlement, encrypted
relay refusal, final frames, notification/bell delivery, history, respawn, and
bounded stalled consumers. The slow-viewer checkout-deletion case passed in the
final review-fix gate. Earlier runs timed out waiting for `ENDED`, including an
isolated retry; the passing rerun does not establish the cause of those timeouts.

## Transport benchmark

The existing production frame-pipeline benchmark passed every gate for all
combinations below. Each workload ran for three seconds. Encryption is actual
AES-GCM application-envelope encryption; the network is simulated bandwidth
serialization plus ACK delay. This is **not** an app paint-latency benchmark or
a measurement of the new Dart prefetch scheduler over a live relay.

The age column is the largest workload p95 from capture start to simulated-link
handoff. Encrypted B/s is the highest workload rate; neither is input latency.

| ACK delay (ms) | Link limit (B/s) | Max workload p95 age (ms) | Max encrypted B/s | Max frames / sliding second | Gates |
|---:|---:|---:|---:|---:|:---|
| 0 | unlimited | 5.1 | 67,933 | 17 | pass |
| 0 | 262,144 | 21.9 | 73,962 | 17 | pass |
| 50 | unlimited | 5.3 | 72,414 | 17 | pass |
| 50 | 262,144 | 20.2 | 73,958 | 17 | pass |
| 100 | unlimited | 4.6 | 60,167 | 17 | pass |
| 100 | 262,144 | 20.0 | 75,439 | 17 | pass |
| 250 | unlimited | 4.5 | 57,115 | 14 | pass |
| 250 | 262,144 | 21.0 | 53,764 | 13 | pass |

Raw JSON reports are generated under `.tmp/terminal-demand-qualification/` by
the command above. The directory is a local qualification artifact, not source.

## Remaining release requirements

- The repository's `LocalTransport` still uses bearer-authenticated loopback
  JSON (`packages/antgrid_relay_client/lib/src/local_transport.dart`). Encrypted
  local qualification therefore cannot be claimed by this change. Relay
  encryption and local authentication were preserved.
- Exercise the actual app with busy hidden terminals on both transports under
  the requested RTT/bandwidth conditions. Record visible startup,
  speculative/late bytes, subscription counts, hidden-cache memory, and input
  latency. The transport benchmark above does not substitute for this run.

With `ANTGRID_DEBUG_PERF=true`, `PerfRecorder` now emits demand counters for
subscriptions, unsubscriptions, first-frame elapsed time, speculative bytes,
discarded-frame bytes, and timeouts, plus gauges for hidden-cache string-memory
accounting and speculative attachments. Existing echo timing remains available.
Byte counters count UTF-8 ANSI payloads, not complete transport envelopes.
First-frame counters measure receipt/application, not presentation to the user.
The 500 ms settling interval and five-second speculative deadline are scheduling
defaults, not measured bandwidth estimates.
