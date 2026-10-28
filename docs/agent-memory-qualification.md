# Local memory qualification

The automatic-save release gate requires actual Claude Code and Codex terminal
runs. Passing storage, transport or MCP tests alone does not qualify either
agent. Native memory remains unchanged in ordinary use; qualification uses
fresh native homes so synthetic findings cannot enter a developer's memory.

## Packaging smoke

Compile the normal bridge entry point and the smoke harness on each target OS:

```sh
bun build bridge/src/index.ts packages/antgrid-agents/src/agents/handoff/db-serialize-worker.ts --compile --outfile .tmp/memory-qualification/antgrid-bridge
bun build bridge/scripts/memory-mcp-smoke.ts --compile --outfile .tmp/memory-qualification/memory-smoke
.tmp/memory-qualification/memory-smoke /absolute/path/to/.tmp/memory-qualification/antgrid-bridge
```

On Windows use `.exe` output names. The harness creates and removes an isolated
local-profile directory, verifies the separate MCP tool table and instructions,
and exercises compiled SQLite/FTS5, duplicate suppression, restart persistence,
correction, forgetting and consumed-operation replay. It does not run models.
Its loopback server supplies a fixed trusted fixture identity; the bridge route
and live-caller tests separately qualify admission.

The `memory-packaging` matrix in `.github/workflows/ci.yml` runs this compiled
smoke on Windows, macOS, and Linux. A configured job is not a recorded pass:
use the completed job results when updating the RFC support matrix.

`bun run --filter antgrid-evals test:evals:memory` exercises the real bridge's
authenticated Iroh project and machine payload paths, including a central
WebSocket outage and a native reconnect after restart. Its stored findings are
fixture data; this test does not qualify a provider's automatic-save behavior.

## Agent preparation and execution

```sh
bun bridge/scripts/memory-agent-qualification.ts --claude /path/to/claude --codex /path/to/codex --output .tmp/memory-qualification/agents.json
```

This command prepares a non-Git fixture outside the repository and fresh native
homes, probes CLI versions and authentication without reading credential files,
and records scenarios with `not_run` metrics. It makes no model calls and does
not copy native histories, instructions or credentials. It retains the fixture
for inspection and later runs. Auth status in the report is only the boolean
result; personal account details are discarded.

Use a new Antgrid profile for the actual terminal run, enable memory once, and
keep the generated native-home overrides scoped to child processes. Supply
authentication through the agent's supported mechanism. With explicit owner
authorization, copy only the required authentication file into the isolated
profile, preserve its access permissions, and verify login without logging
credentials. Do not copy native history, memory, or configuration, or point the
fixture at the existing native home. Verify the
reported project directory has no Git repository or inherited instruction
files. Launch each scenario in its named durable session through Antgrid so
the core supplies project, session, checkout and live-run identities. Do not
fabricate those fields in the model prompt.

The live driver uses authenticated desktop-owner transport to create real
Antgrid terminal sessions. Once the prepared native homes are authenticated
and authentication-file copies are authorized, run:

```sh
bun bridge/scripts/memory-agent-live.ts .tmp/memory-qualification/agents.json claude:automatic_save,codex:cross_agent_recall,codex:independent_repeat,claude:correction,codex:forget
```

Each sequence gets a fresh non-Git project, Antgrid profile, and native homes;
only the authentication files follow. The driver introduces `correction.txt`
when the correction scenario begins, so the first finding cannot already
include the later evidence. It uses Claude print mode and Codex exec mode in
real PTYs with bypass approval policy, records the mode, and shuts down its
host afterward. It does not drive the Flutter UI.

The authorized hook follow-up adds fixed usage guidance through Codex
`SessionStart` and OpenCode's terminal plugin system transform. Bootstrap must
use the actual inherited live caller and return only the four settings flags.
Keep the ordinary task prompts unchanged; neither hook may include stored
memories or transcripts. Retain the original MCP-only failures as separate
observations. Codex's normal terminal can be selected with
`codex-tui:automatic_save` instead of `codex:automatic_save`; run it in a fresh
sequence so a previous save cannot conceal a miss. Its completion is measured
from real hook work-status transitions, followed by a controlled session stop.

OpenCode requires its terminal plugin to be injected and a usable installed
CLI and provider account for live qualification. An explicit `OPENCODE_CONFIG`
currently bypasses that injection. Mock plugin tests and compiled asset loading
establish wiring, not model-selected automatic saves. Record a missing CLI as
blocked and do not claim live OpenCode support from those tests.

For OpenCode, prepare the optional executable and explicit provider/model, then
authenticate its isolated profile before running the same scenarios:

```sh
bun bridge/scripts/memory-agent-qualification.ts --claude /path/to/claude --codex /path/to/codex --opencode /path/to/opencode --opencode-model openai/gpt-6.1-sol --output .tmp/memory-qualification/opencode-agents.json
bun bridge/scripts/memory-agent-live.ts .tmp/memory-qualification/opencode-agents.json opencode-tui:automatic_save,claude:cross_agent_recall,opencode-tui:independent_repeat,opencode-tui:correction,opencode-tui:forget
```

The prepared OpenCode home separates `data`, `config`, `state`, and `cache`
through child-only XDG overrides. An explicitly authorized auth-only copy goes
to `<native_homes.opencode>/data/opencode/auth.json`, retaining its original
permissions; no user configuration or history follows. Provider presence in
`auth list` is not proof that credentials work; a successful provider turn is.
The recorded run uses OpenCode's default approval policy. Interactive completion
uses the real plugin's working-to-done transition, followed by a requested stop;
a nonzero teardown exit after a completed turn is recorded separately from a
failed turn. Native SQLite message/part records supply tool calls and usage,
without summing step usage again or treating a zero native cost as a zero bill.
System-transform text is not retained there, so do not claim direct inspection
of the model's received hook context from that database alone.

`opencode:automatic_save` selects a fresh `run --format json` terminal instead.
Use TUI-origin sessions for durable replay: the run subcommand takes a
positional prompt, and changing a durable session's stored argv is not part of
this harness. Reverse sharing can be checked with
`claude:automatic_save,opencode-tui:cross_agent_recall` in a fresh sequence.

To replay a forgotten operation after a host restart, name its original
durable Antgrid session and the prior result file:

```sh
bun bridge/scripts/memory-agent-live.ts .tmp/memory-qualification/agents.json claude:replay:<original-session-id> <prior-results.json>
```

This resumes that session in its existing isolated profile. A generated local
verification script uses the live identity inherited from Antgrid and reports
only refusal codes. `FORGOTTEN` demonstrates replay suppression; a missing or
stale caller refusal would not. This explicit verification task is separate
from the ordinary-work automatic-save scenario.
For an OpenCode TUI-origin session, select
`opencode-tui:replay:<original-session-id>` with its prior results file.
OpenCode 1.19.0 routes `--session` directly to history and does not submit the
accompanying `--prompt`. For resumed OpenCode checks, the driver waits for the
current TUI to be ready and stable, then submits the unchanged verification
prompt once through authenticated `terminal:input`. The result records that
setup action and submission time. A launch timeout with no new native user
message is a prompt-delivery block, not a failed memory operation. This
workaround belongs to the qualification harness; it does not change Antgrid's
production launch behavior.

Execute the prompts in the generated report in order. The first prompt asks
only for ordinary work; adding an explicit remember request invalidates the
automatic-save observation. Inspect the local store through the app after each
run, without showing stored memory to the next agent in its startup prompt.
Record every tool invocation, its latency and returned durable IDs. Compare
claims with the fixture evidence, including incompatible Windows/macOS
conditions and the unapproved proposal. Inspect correction history, then
forget and replay the original and duplicate operation keys through the test
driver. Neither may restore content.

Repeat the sequence with agent order reversed. Add unrelated project and
checkout sessions, a resume of the same durable session, a new/forked session,
profile/project pauses, a lost save response, and a restart with pending work.
After forgetting during a pending retry, inspect canonical storage, search,
history and the pending-operation status. Use the real app for enablement,
pause, correction, history, forgetting and export inspection.

## Measurement and verdict

Each scenario row records `status` (`not_run`, `passed`, `failed`, or `blocked`),
a concrete result, and these metrics:

| Metric | Meaning |
| --- | --- |
| `save_misses` | Useful, evidence-supported findings not automatically saved |
| `incorrect_saves` | Unsupported, overgeneralized, credential-bearing, or redundant recalled findings saved |
| `retrieval_misses` | Expected eligible memories not found by the agent |
| `duplicate_records` | Additional eligible records for the same finding; note paraphrases separately |
| `extra_tool_calls` | Additional memory calls beyond the scenario's successful path |
| `latency_ms` | End-to-end scenario time, with individual tool timings retained separately |
| `input_tokens`, `output_tokens` | Reported provider usage; unknown values remain null |
| `cost_usd` | Reported actual charge; never infer zero from missing billing data |

Record CLI/model versions, OS, fixture revision, terminal approval policy,
prompt, MCP tool availability, conditions, and whether full content avoided an
extra get call. Missing credentials or a missing executable is `blocked`, not a
save miss. Preparation-only rows stay `not_run`; null metrics are not zeros.

Automatic saving is unqualified until both required agents complete the
sequence with measured results. If direct tools and static guidance miss useful
findings, retain the failure report and propose a targeted adapter follow-up.
Do not introduce transcript capture, background extraction or saved-content
injection to make the qualification pass. The explicitly authorized static
lifecycle guidance is qualified separately from the original MCP-only trial.
