# Multi-Machine Session — Build Plan

**Spec:** `docs/multi-machine-session.md` (Draft v0.15). Every wave below cites the spec section it implements; nothing here re-decides anything the decision log (spec §12) has closed.
**Status:** Draft, 2026-09-04

## How the waves are cut

- **Each wave gates and commits on its own.** Bridge, relay-client and app tests per workspace, one `flutter analyze` from the controller, then a commit. A wave that cannot go green alone is cut wrong.
- **Each wave is independently useful**, so a stalled feature never leaves half a wire format in the tree. Waves 0 and 1 fix things users want regardless of this feature.
- **Nothing crosses the licence boundary.** Every new message type is an app-level schema in `bridge/src/protocol.ts` (ELv2), hand-mirrored into `app/lib`. `antgrid-wire` and `antgrid_relay_client` gain nothing; the relay is untouched.
- **The message-type checklist applies to every type added**: schema → `AbMessageSchema` union → `KNOWN_TYPES` → `index.ts` switch → Dart parser. Membership and task traffic is per-session, not per-checkout, so nothing joins `CHECKOUT_VARIABLE_MESSAGE_TYPES`.

Dependency graph:

```
W0 MCP injection ─┐
                  ├─► W3 session bus ─► W4 app ─► W5 two-bridge eval + docs
W1 N app sessions ┤        ▲
                  │        │
W2 membership ────┘   (W4 shell can start after W2)
```

W0, W1 and W2 are independent of each other and can run in parallel.

---

## Wave 0 — MCP tools injected per spawn (spec §4.6, D12)

**Why first.** Today the MCP server is installed only by `plugin/setup.ts`, so a session the app started has no tools at all. The session tools of W3 need a delivery path that exists for every spawn; the five existing tools benefit immediately.

**Scope**
- The MCP server becomes a **bridge subcommand** (`antgrid-bridge mcp`), launched by absolute path the way `resolveHookCommand` bakes `process.execPath` (`bridge/src/hook-command.ts`). `bridge/plugin/mcp-server.ts` is the code to move; it stays stdio and keeps calling the loopback `api-server.ts`.
- `AgentSpec` (`bridge/src/agents/types.ts`) gains an `mcp` profile beside `hooks`, with a per-agent `inject` in `agents/<key>/`. Claude Code and Codex first; an agent that declares none gets none — fail-open, same as hooks.
- `augmentAgentLaunch` (`bridge/src/agent-launch-augmenter.ts`) applies the profile at every spawn. The injected entry carries the API port and the terminal id, so the server can name its own session without being told (§4.5 "role is derived by the bridge").
- `api-server.ts` resolves a caller's session from that terminal id.

**Gates:** bridge tests; a `smoke-mcp-binary.ts` beside `bridge/scripts/smoke-hook-binary.ts` that runs the compiled binary's subcommand. The MSIX `<Application>` declaration already covers the binary (CLAUDE.md gotcha), and the smoke script cannot prove that, exactly as for hooks.

**Done when** a session started from the app can call an existing tool with no `antgrid setup` ever run on that machine.

---

## Wave 1 — N concurrent app sessions per bridge (spec §9, D8)

**Why.** A bridge admits one app device today; a second displaces the first (`relay-client.ts`, the takeover block near `session-takeover`). The lead's desktop app and the phone must both be attached to the peer bridge. This also fixes desktop and phone sharing one machine, which users want regardless.

**Scope**
- `bridge/src/relay-client.ts`: one established session per app device instead of one per bridge. Takeover narrows to **same device rekeying**; a different device is admitted alongside. Every caller of the singular `currentPeerPubkey()` — `currentPhoneAllowed()` in `agent-core.ts`, the backfill path, the loopback owner promotion — becomes per-connection.
- Route fan-out: bus frames go to every established session; replies go to the session that asked.
- App side needs nothing new for admission. The Dart `MachineSession` takeover handling stays as is, since a same-device rekey still arrives as `session-takeover`.

**Gates:** bridge tests; an eval in `evals/tests/gate-*.test.ts` that attaches two `RelayClient`s to one agent and shows both receive a state snapshot and neither is displaced. `dart test` in `packages/antgrid_relay_client` if anything there moves.

**Done when** phone and desktop drive one machine at the same time.

---

## Wave 2 — Session membership and the Capability Card (spec §3.1, §3.3, §5.1, §5.4, D9–D11)

**Scope**
- `SessionEntrySchema` (`bridge/src/protocol.ts`) gains optional `members[]` and `memberOf`. `session:create` gains `memberOf` plus the brief; the peer bridge persists its half in its own `sessions.json`. Mirror in `app/lib/models/session_entry.dart`.
- **Capability Card** as a bridge-observed OS + repo record, available before any agent runs. The project catalog advert (`agent:projects`) gains the git remote, which the dialog's auto-match needs (§7.5).
- **Deletion rules** (§5.4) in the session manager: cascade, confirm-then-delete, self-delete on disown, orphan marking. One consequence of D7 to write into the spec while doing this: **the lead bridge cannot reach the peer bridge**, so the cascade is issued by the lead's app, one delete per member, and the lead bridge records each outcome ("released" or "released, delete refused"). The existing `WORKTREE_DIRTY` / `WORKTREE_UNPUSHED` refusals apply unchanged.
- Brief delivery: on create, the peer bridge feeds the brief to that session's Handler as `handler:instruct` (§7.2), wrapped by the brief template of §5.2 (the template module lands here and W3 extends it). Lifts remain per member by construction, since the instruction is text on that engine.

**Gates:** bridge tests for persistence and every row of the §5.4 table; `flutter test` for the model mirror.

**Done when** a peer session can be created with `memberOf`, shows up on both bridges' rows, and is deleted by every rule in §5.4, all driven by a test client with no UI.

---

## Wave 3 — The session bus (spec §3.2, §4.1, §4.2, §4.5, §5.2, §6, D13)

The largest wave, and the only one that touches every layer of the bridge. Cut it into three commits inside the wave.

**3a — Stores on the lead bridge.** Task store with per-task monotonic `seq`, ack, and duplicate-is-no-op; pending-request store with expiry and cancel; artifact store that survives session end (§6.3); message log. Pure modules under `bridge/src/session-bus/`, unit-tested with no transport.

**3b — Wire and forwarding.** Message types for task transitions, acks, messages and artifact references, addressed per member. The lead bridge hands outbound frames to the loopback owner **only** (`local-listener.ts`, §4.1 first invariant), never to the bus; the app forwards them over its connection to the peer bridge and relays the peer's frames back. Retry until acked.

**3c — Tools, delivery templates and the wake.** The MCP subcommand from W0 exposes the lead and peer tool tables of §4.5, role derived from the calling terminal. Every line delivered into an agent is rendered by one template module (`bridge/src/session-bus/delivery.ts`, one function per delivery kind: brief, task, wake, answer) per §5.2: provenance, expected action and answering tool, the other agent's content fenced as data, scope restated. Written and reviewed as prompts, with a snapshot test per kind. Delivery into an agent is a line submitted at the **next turn boundary**: `work-status.ts` already observes turn open and close, and `SessionAdapter.injectReply` (`PtySubmitQueue` or the chat driver) is the submit path. Never mid-turn (§5.2). The runaway guard (§8) caps tasks per session and per hour.

**Gates:** unit tests for 3a idempotency (duplicate `seq`, out-of-order ack, retry after drop); bridge tests for 3b addressing (a bus subscriber must never see task traffic); an eval for 3c with one real agent calling `assign-task` and observing the wake land after the current turn, not inside it; snapshot tests for every delivery template, plus one that feeds a finding containing instruction-shaped text and asserts it arrives fenced.

**Done when** a lead agent on machine A assigns a task, a test client playing the carrier forwards it, and the peer agent on machine B receives it as a Handler-delivered line and reports back with an acked transition.

---

## Wave 4 — The app (spec §4.1, §7.1, §7.5, D14)

**Scope**
- **Carrier.** The desktop app forwards W3 frames between the loopback owner socket and its connection to the peer machine. That connection is **pinned against registry eviction** (§4.1 second invariant) in `connection_supervisor.dart` / `relay_connection.dart` for as long as the session has members.
- **Kebab.** Add machine joins Switch mode and Move Handler in `_SessionOverflowMenu` (`app/lib/widgets/agent_panel.dart`); Remove from session appears when a peer tab is selected.
- **Add-machine dialog**, exactly the §7.5 table: machine, project auto-matched by git remote, inline card, tool, model via the `handler_judge_chip.dart` pattern over `cachedModelsFor` with free text, brief, Add / Cancel. Uses the new-session composer's machine and agent pickers rather than new ones.
- **Member tabs** above the transcript; selecting a member re-targets the transcript, composer and every checkout-scoped panel to that member's session. The peer's composer is fully interactive.
- **Session list**: member-of badge next to the existing isolation and Handler badges in `session_row.dart`; orphaned state rendered when the lead is unreachable.
- **Queue**: no change, but a peer's stalled task should read as such on the phone — verify the existing approval surface names the machine.

**Gates:** `flutter test`; one `flutter analyze` from the controller (warnings count, `analyze_files` does not see them); `npm run check:font-tokens`; the design rules in `app/CLAUDE.md`.

**Done when** a user on the desktop adds a second machine from the kebab, writes the brief, and watches the peer's transcript from the member tab.

---

## Wave 5 — Two-bridge eval and docs

**Scope**
- A SIBLING helper, `evals/helpers/two-bridge.ts`, composes two `setupTestEnv()` bridges onto one in-process relay (`harness.ts` is a shared surface and stays untouched) and plays the desktop carrier as a two-legged test object: the lead's loopback owner socket and a `RelayClient` on the peer's project stream. `evals/tests/gate-multi-machine.test.ts` covers: expand, brief delivery, assign → ack → report, cancel, delete cascade with one refused member, and orphan on lead loss.
- Docs: `docs/architecture.md` message flow, `bridge/CLAUDE.md` (session bus, MCP subcommand), `app/CLAUDE.md` (carrier, member tabs), and the CLAUDE.md conventions list for the new mirrored constant if W2 adds one.

**Done when** `bun run --filter antgrid-evals test:evals` runs the suite green on Windows. The POSIX container run is a separate step: it needs an image carrying git and a copied (not bind-mounted) tree, which is a harness question rather than a claim about this wave's code.

---

## Risks to watch, by wave

| Wave | Risk | Where it bites |
|---|---|---|
| W0 | A compiled single-file binary invoking itself with a fresh subcommand on Windows Store builds | only the packaged MSIX shows it; the smoke script cannot |
| W1 | Every place that assumes one phone: policy, backfill, focus, notifications | grep `currentPeerPubkey` and `ownerSocket` before starting |
| W2 | Delete cascade orchestrated by the app, not a bridge | a closed app mid-cascade leaves members partly released; the orphan rule must cover it |
| W3 | A wake landing mid-turn because turn tracking missed a boundary in chat mode | eval must run in both terminal and chat mode |
| W4 | The pinned peer connection kept alive after the session ends | unpin on every §5.4 path, not only on delete |
| W5 | Two PTY-backed agents in one eval process on Windows | port space and job objects; keep it out of any sweep, as all evals are |
