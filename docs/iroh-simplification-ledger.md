# Native transport simplification and reliability ledger

Checkpoint: 2026-09-22. The six-stage implementation is complete in staged commits; final qualification remains bounded by the environment limits below.

## Delivery

| Stage | Commit | Result |
| --- | --- | --- |
| Plan | `0cda16a0` | Saved the coordinated beta cutover, bounded cleanup, lease deadlines, command uncertainty, and acceptance gates. |
| Central admission | `f0e862c3` | Reserved socket admission before upgrade, fenced async authentication, simplified presence/state, and validated configuration. |
| Connection ownership | `5d671bf7` | Split native and central supervisors, made central conflict sticky, bounded native teardown, and rate-limited presence wake-ups. |
| Identity and leases | `3401cffe` | Serialized runtime replacement/sign-out, enforced original lease deadlines, and fenced queued dispatch. |
| Bridge ownership | `f545a753` | Consolidated native peer ownership and retirement, removed optional payload paths and presence-retained E2E state, and injected lifecycle seams. |
| Peer frame v3 | `5e7cebe9` | Introduced peer-bound frame v3, removed route identities/aliases, generated TS/Dart vectors, and exposed `notSent`, `confirmed`, and `outcomeUnknown`. |
| Evaluations | this commit | Split central/native eval operations, added strict snapshots and LIFO cleanup, removed stale suites/helpers, added lifecycle diagnostics, combined-failure tests, and a seeded native fault soak. |

This is a coordinated beta upgrade. Peer-frame v2 is rejected; there is no dual decoder, transport feature flag, route-frame alias, application WebSocket payload fallback, or automatic mutation replay. Existing endpoint registrations and endpoint keys remain valid because the accepted plan requires an upgrade without re-enrollment or database reset.

## Verification

- `antgrid-wire`: typecheck passed; 111 tests passed, including generated v3 bytes/constants and v2 rejection.
- Relay: typecheck passed; 173 tests passed, including concurrent hello, admission release, delayed/closed verification, asymmetric presence, epoch/replay/skew, push/policy/revocation, and binary/retired-verb rejection.
- Web: typecheck and production build passed; 658 tests passed.
- Bridge: typecheck passed. The full suite reached 4,834 passed and 16 skipped with seven failures caused by an inherited `ANTGRID_RUN_ID` in hook tests plus one stale auth fixture. The affected hook rows passed with that external variable removed, and the repaired fixture passed 3/3; the broad run is therefore recorded as non-clean rather than silently promoted.
- Flutter: `flutter analyze` passed. The full suite reached 4,215 passed and two skipped with one timing-sensitive terminal-demand failure; that row passed in isolation. Focused lifecycle/transport tests passed, including conflict during native recovery, sign-out during handshake, lease expiry during queued work, and stale-generation fencing.
- Dart relay client: `dart analyze` passed and 264 tests passed. Peer transport analysis passed and 29 tests passed. The Dart eval client analysis passed.
- Eval TypeScript typecheck passed. The self-contained serialized sweep passed 100 tests with five declared skips and zero failures. It includes real HTTP/OAuth/Prisma authorization and a real direct-loopback native host; the current revocation closure was about 21.95 seconds.
- The native-DLL group passed 17 tests with one declared skip. It covers Dart/Bun interoperability, project/file/terminal behavior, and three peer-resume cycles; observed direct-loopback recovery was about 39.6-47.4 ms.
- Focused session-bus gates passed 4/4 and multi-machine gates passed 3/3 after tests used current run generations and read-only SQLite observation. The terminal slow-viewer row passed three consecutive runs after its producer was bounded by wall time.
- Font-token script passed through Git Bash. The npm wrapper itself cannot run here because it selects unavailable WSL `/bin/bash`.
- The required 30-minute seeded loopback fault soak passed: one test, 1,830 assertions, 1,800.77 seconds, seed `0x41c6ce57`. It found no duplicate mutations, stale relay sessions/admissions, retained cycle ownership, or process RSS growth beyond its 128 MiB bound.

The Rust real-backend relay probe is an explicit infrastructure gate and is excluded from the self-contained sweep. A current attempt timed out at 100 seconds without producing qualifying evidence; build `iroh-relay`'s `real_backend_gate` example before rerunning it.

## Qualification limits

Forced-relay native QUIC, blocked-UDP and WAN transitions, physical-device background/resume, desktop sleep/wake, platform packaging/signing, and comparative performance remain unqualified. Direct-loopback timings are diagnostic observations, not performance acceptance.

No deployment, Aspire restart, production configuration change, push, database reset, or re-enrollment was performed.
