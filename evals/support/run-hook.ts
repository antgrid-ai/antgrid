// Standalone hook-invocation runner for session-bus evals.
//
// Spawned as a CHILD of a sink session's own PTY process (never by the test
// process directly), so it inherits the exact `ANTGRID_RUN_ID`/`ANTGRID_API_PORT`/
// `ANTGRID_TERMINAL_ID` the bridge stamped onto that PTY at spawn — the same
// environment a real agent's hook subprocess runs under. `hook-runner.ts`'s
// `buildPosts` reads `ANTGRID_RUN_ID` from ITS OWN env and stamps it onto every
// post body; there is no other way to produce a `/turn-start` or `/notify` call
// the bridge's `acceptsHookRun` runId-staleness gate (session-manager.ts) will
// accept, short of forging a loopback API that only exists to keep a stale
// hook from a dead process run from reaching a live one.
import { appendFileSync } from "node:fs";
import { runHookInvocation } from "../../bridge/src/hook-runner";

const [, , agent, event] = process.argv;
await runHookInvocation({ agent, event });

// Best-effort completion signal for the test that triggered this run: hooks
// are advisory and `runHookInvocation` swallows its own failures, so this says
// only that the POST was attempted, not that the bridge accepted it — enough
// to stop a caller guessing a fixed delay for an async spawn chain (PTY → sink
// script → this process → loopback POST) that has no other observable edge.
const sink = process.env.ANTGRID_EVAL_SINK;
if (sink) {
  try { appendFileSync(sink, `HOOK_DONE:${event}`); } catch { /* best-effort */ }
}
