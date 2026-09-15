# Iroh migration task ledger

Plan: [approved scope](iroh-migration-plan.md). Existing prototype and research
are preserved. Status refers to production implementation, not prototype smoke.

| Work | Status | Evidence |
| --- | --- | --- |
| Save plan / inspect existing boundaries | Complete | Plan saved; existing changes preserved |
| Dart PeerLink / WebSocket separation | Implemented | Full package tests: 296 passed; analysis clean |
| Bridge reusable peer-session owner | Implemented | Full bridge: 4,840 passed, 16 skipped, one scan timeout; isolated entitlement rerun: 13 passed; typecheck clean |
| Wave 1 regression gate | Component gates passed | Dart terminal E2E: 6 passed; full eval sweep completed, fixture corrections verified separately |
| Endpoint enrollment / policy / outbox | Implemented, staging unqualified | Full web: 661 passed; real HTTP authorization gate: 25 assertions; combined real backend/native host revocation gate passed |
| Protected keys / authoritative leases | Implemented | Native Dart: 15 passed, analysis clean; restored secure records and missing enrollment fail closed; desktop resume fences host leases |
| Upstream relay hooks / Rust service | Implemented, staging unqualified | Locked upstream 1.2.0 service; six fence/accounting tests and actual TLS routing/disconnect test passed, including older 1.0.0 protocol compatibility; combined real backend/service gate passed 11 assertions |
| Native host/app integration / selection | Implemented | Source and compiled HostServer/native/E2E smoke passed terminal input/output, frame ACKs, managed-checkout Git, two projects, central outage and immediate remote-access-off |
| Packaging / Apple Silicon / operations | Partially verified | Flutter-built Windows native DLL passed compiled Dart smoke; full app build blocked by missing Visual Studio ATL; CI/monitoring YAML and Compose config parse; Docker daemon/physical builds unavailable |
| Final local gates | Component gates passed; full E2E not clean | Wire 119 passed; relay 193 passed; Flutter 4,208 passed, two skipped, analysis clean; original full E2E sweep: 106 passed, 28 skipped, 20 failures; 13 fixture regressions corrected/rechecked; installed-agent follow-up below; uncommitted-vector guard remains |
| Physical/staging/security/performance qualification | Unqualified | Operator infrastructure and physical platforms required |

Final bounded checks: site build and browser contracts passed (38 passed, two
skipped), with its frozen lockfile unchanged. Relay byte accounting now serializes
recording with identity binding, preventing pre-authentication bytes from being
counted twice. Anonymous rejected traffic remains unattributed; admitted traffic
includes pre-authentication transport overhead. Concurrent binding and completed
connection totals are covered by the final seven-test Rust gate.

## Installed-agent follow-up — 2026-09-15

All six previously failing installed-agent scenarios passed focused runs with
authorized access to the installed authenticated CLIs: Codex four tests/19
assertions and Claude two tests/18 assertions. No production driver changes were
needed. The restricted environment reproduced the Claude failures; subprocess
diagnostics did not distinguish credential access from network access.

Chat collectors now honor the full bounded turn deadline and surface driver
errors. Claude response evidence requires an assistant message, rather than the
echoed user prompt. Dedicated Claude/Codex workspace scripts support focused
reruns. See [Claude evidence](iroh-e2e-claude-handoff.md).

Envelope vector regeneration produced identical bytes and its five schema tests
passed (37 assertions). The committed/git-clean guard is unchanged and remains
pending the migration commit. These focused checks do not constitute a new full
E2E sweep.

Final verification after collector edits: `bun run --filter antgrid-evals
test:evals:codex` passed four tests/19 assertions in 27.90 seconds;
`bun run --filter antgrid-evals typecheck` exited zero, including the Claude
changes. `git diff --check` passed.
