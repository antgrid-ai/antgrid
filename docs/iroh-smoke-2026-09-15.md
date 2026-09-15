# Aspire smoke capture — September 15, 2026

Capture: `.tmp/smoke-monitors-20260915-103442/`. The manifest records worker
PIDs and start/stop times. All capture workers were stopped and remote Netwatch
was explicitly disarmed after the user finished. Application instances were
left running.

Analysis excludes Aspire's historical backlog and Netwatch's initial ring
snapshot before 05:04:42 UTC (10:34:42 IST). Aspire output contains duplicate
historical entries; these must not be counted as new reconnects.

## Findings

- Netwatch captured 3,664 events in the test window, including 1,174 frame IDs
  observed at both bridge and app. No recorded drop/decrypt-failed events.
  This is metadata evidence, not proof that every user action succeeded.
- Three fresh E2E sessions established at 10:37:36.794, 10:38:14.197 and
  10:40:43.671 IST. Relative to the first logged Android resume in each cycle,
  establishment took approximately 2.51, 3.74 and 5.44 seconds.
- The final resume had a token request socket-abort error at 10:40:38.182,
  then AUTHORIZATION_UNAVAILABLE at 10:40:40.068. A late socket authentication
  at 10:40:40.445 was followed by another connection attempt and successful
  E2E establishment. This transient retry remains worth investigating;
  backend token/authorization requests around it returned 200, so a backend
  authorization denial is not established by these logs.
- Android logged sends dropped while no E2E session existed during reconnect.
  Message types are not included in those diagnostics, so the capture cannot
  determine whether these were hydration requests or user actions.
- At 10:38:34.499 a project stream was temporarily unbound at the peer. The
  host muted it and resumed delivery on rebind at 10:38:34.560 (61 ms).
- At 10:37:51.613 the Codex hook-alive check failed for terminal
  4f36b31e-88c4-4b8b-af09-c28360cefbbb. The bridge enabled its OSC scanner
  fallback for notifications/title; the hook failure itself remains unresolved.
- Antigravity certificate-cache priming reported HTTP 404 at 10:37:58.148.
  Android also reported Play update-service binding failures and terminal
  glyph/grapheme fallbacks. Firebase startup errors in the backlog predate
  this capture window.
- Captured backend response lines in the window: 97 HTTP 200 and two HTTP 302;
  no HTTP 4xx/5xx response lines were found. No new host fatal error or native
  crash appeared in the inspected window.

The long offline interval beginning 10:39:08 followed an Android background
event at 10:39:03; foreground resume was logged at 10:40:38. Do not report that
entire background interval as foreground recovery latency.

This test exercised the default WebSocket path. It does not qualify native
Iroh or establish that the host-resume invalidation fix was exercised: the
observed resume events were Android lifecycle transitions.

## Android resume follow-up and fix

Two code paths explain unnecessary authorization retries without backend denial:

1. AppShell registered both `onRestart: _reconnectRelay` and `onResume: _resume`.
   Flutter emits both in a foreground transition, matching the paired resume
   log entries in the original capture. Both paths invalidated authorization.
   AppShell now refreshes once, at `onResume`.
2. `AuthorizationLease.refreshFresh` invalidated an in-flight refresh and waited
   for it, but a concurrent connection's `refresh()` still joined that old
   request. It returned false while the resume refresh subsequently succeeded.
   New admission now joins a published fresh-request barrier. Overlapping fresh
   requests share it; old responses and subsequent revocations remain fenced.

The new lease regressions failed against the old implementation and passed
after the fix. They cover admission waiting, refresh serialization and revocation
while refreshing. The Flutter lifecycle regression drives paused → hidden →
inactive → resumed and asserts one manager refresh.

Validation:

- Pure Dart authorization, selection and enrollment tests: 15 passed.
- Flutter AppShell, peer runtime provider and connection supervisor tests:
  19 passed.
- Serial Flutter analysis: no issues (83 seconds). Pure Dart transport analysis:
  no issues. `git diff --check`: passed.
- Hot-restarted only the Android app through Aspire's Flutter control endpoint.
  The Windows host and terminals were not restarted.
- Three ADB cycles (7 seconds background, 7 seconds foreground) each emitted
  exactly one AppShell resume, one central connection/authentication and one
  fresh E2E establishment. Resume-to-E2E times: 3.225, 2.754 and 3.256 seconds.
- No authorization-unavailable, socket-attempt failure, no-session send-drop,
  unknown-stream or host warning/error appeared in those three cycles. Android
  Play update-service binding warnings remain.

Evidence: `.tmp/android-resume-validation.log`,
`.tmp/android-resume-validation-host.json`, and
`.tmp/android-resume-validation-start.txt`. Live cycles ran at approximately
10:50–10:51 IST. These short emulator cycles do not qualify long sleep, physical
devices, command outcomes or native Iroh. The original OS socket abort occurred
around return from a longer background interval; its exact OS cause is not
established, and token HTTP requests remain without their own explicit timeout.
Changes are uncommitted.

## Follow-up commit and user validation

The user reported successful validation after two minutes backgrounded on September 15. No additional timing measurements or logs were supplied for that run. This commit includes the Windows setup documentation, emulator connection and host/Android resume fixes, regression tests and investigation records. Earlier uncommitted-status notes are historical. Token minting still has no explicit HTTP request timeout; longer sleep, network-transition, physical-device and native Iroh qualification remain open. No production preference was enabled.
