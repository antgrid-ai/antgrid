# Installed Claude E2E verification

## Cause and changes

The original full-eval log reported two Claude failures: missing `agent:turn-end`
after a text prompt, and missing completion before the auto-title assertion.
A focused sandbox run reproduced both (0 passed, 2 failed). An authorized run
with access to the installed Claude login and network passed both after the
collector corrections below. No production Claude driver change was required;
the reproduced failure is environment-dependent rather than evidence of a peer
transport regression. The sandbox run did not expose enough subprocess
diagnostics to distinguish credential access from network access as its precise
environmental cause.

`evals/tests/chat-session-claude.test.ts` now waits for the remaining bounded
60-second turn budget instead of abandoning the first test after a 10-second
quiet interval. It requires the PONG message to have assistant role, so the
driver's echoed user prompt cannot satisfy the response assertion. Both turn
collectors surface `agent:error` directly, and the auto-title case additionally
requires a successful `end_turn` before checking the actual session rename.
No prompt is replayed on timeout and no assertion or availability gate was
removed.

The parent added the dedicated `test:evals:claude` workspace script; shared chat
helpers and other agent implementations were outside this task's ownership.

## Checks

- Reproduction: `bun run --filter antgrid-bridge test
  ../evals/tests/chat-session-claude.test.ts`, sandboxed: 0 passed, 2 failed,
  exit 1, 80.90 seconds (original collectors).
- Verification: `bun run --filter antgrid-evals test:evals:claude`, authorized
  installed-login/network access: **2 passed, 0 failed, 18 assertions**, exit 0,
  15.05 seconds. Real assistant text and successful turn completion passed;
  the second real turn completed and auto-named its session.

Only fixture PONG prompts were sent. There are no pending tool sessions or
Claude-specific production edits. Parent integration owns the final TypeScript
gate and full-eval result aggregation.
