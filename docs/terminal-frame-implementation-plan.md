# Serialized terminal frames: implementation plan

Status: coordinated app/bridge replacement implemented; release qualification is
tracked below. Both components must be upgraded together.

The implementation uses snapshot-only viewing. Local-transport encryption and
the full supported-host real-agent/paint-latency qualification remain open gates;
the existing bearer-token loopback transport is not encrypted by this change.

## Outcome

Make the bridge's headless VT the authoritative terminal state. Send independent
serialized screens at a maximum of 20 frames per second to each active viewer.
Retain normal-buffer scrollback separately and load it on demand. Preserve native
OSC 8 hyperlinks, keyboard and mouse behavior, terminal lifecycle, and existing
transport authentication/encryption boundaries.

Frames are the only app display protocol. Unsupported terminal protocol versions
require an upgrade. Attach failures, unsubscribe, timeout, and reconnect never
resume raw PTY streaming or legacy attach snapshots. Raw bytes remain available
to bridge-internal consumers such as port detection and hooks.

Remote recovery also distinguishes missing terminals from failed displays.
`terminal:subscribe` first attempts archived restoration, then returns a
request-correlated `UNKNOWN_TERMINAL` if no run exists. The app preserves retained
content as unavailable and suppresses automatic reattachment until a new start.
Session-list recovery retains the 15-second timeout, accepts compatible concurrent
default-list replies, and clears late timeout notices. Checkout cleanup advances
on unchanged listings so deleted bundles cannot retain their hydrators forever.
These changes do not introduce output governors, raw-stream recovery, additional
timeout grace, or changes to relay budgets and tree sequence policy.

The [local prototype](terminal-frame-prototype.md) establishes basic serialization,
native Ghostty link restoration, and bounded delivery. It does not establish
production agent compatibility, scalable history, or transport integration.

## Design decisions

### Authoritative state and capture

- Maintain one headless VT per PTY run, shared by all viewers. Feed it every output
  chunk in order, including while disconnected, backgrounded, or access-disabled.
  Keep internal output consumers such as port detection and agent hooks working.
- Promote the experimental frame source into the terminal implementation after
  its state and query handling are corrected. Avoid maintaining a second emulator
  exclusively for each viewer.
- Process output, resize, mode changes, queries, and exit barriers in one ordered
  pipeline. Capture at a completed parser boundary; never append `pendingTail()`.
- Capture changed state at most once per 50 ms and reuse the immutable result
  across viewers at the same revision. Serialize only when a viewer has capacity.
  No viewers means no periodic serialization, while parsing and history continue.
- Respect DEC 2026 synchronized output. Retain the prototype's bounded timeout
  initially, mark timeout frames, and measure them. Do not wait indefinitely for
  a guest that never closes a synchronized update.
- Frames carry authoritative dimensions, buffer identity, cursor/input state,
  and a history boundary. They include the bounded visible state needed for buffer
  restoration, never accumulated scrollback. Apply dimensions before the body.
- Treat parser overflow as loss of authoritative state. Pause the affected view
  and recover from a valid recording boundary or expose a recoverable error;
  never discard input bytes and keep issuing apparently valid frames. First
  investigate parser batching and PTY pause/resume support on each platform.

### Per-viewer negotiation and identity

The `terminalFramesV1` capability is mirrored in bridge `app:ready` and both Dart
local and remote hello paths. A successful subscription supplies the authoritative
run and attachment IDs; no other display mode is negotiated.

Key a subscription by authenticated connection, project stream, checkout, terminal,
PTY run ID, and attachment ID. The bridge binds it to the actual inbound source;
a client-supplied viewer ID is not authorization. A same-name PTY respawn gets a
new run ID. Reconnect or reattach gets a new attachment ID.

Application protocol surface (`bridge/src/protocol.ts`):

| Operation | Essential fields and behavior |
|---|---|
| Subscribe / subscribed | Terminal and checkout, requested version; selected mode, run ID, attachment ID, dimensions, history availability |
| Frame | Run/attachment IDs, increasing frame ID and source revision, dimensions, ANSI, history boundary, synchronized-output timeout flag |
| Frame acknowledgment | Run/attachment IDs and cumulative highest consumed frame ID |
| Unsubscribe / pause | Retire viewer state and stop serialization work for that viewer |
| History page request / response | Run ID, opaque cursor, bounded row/byte limits; styled rows, links, wrap metadata, next cursor, retention boundary |
| Display/history status | Explicit unavailable, expired, oversized, or recovery state; terminal exit remains a lifecycle event |

Use Zod for every wire payload, including RPC parameters/results. If using new
message types, update `AbMessageSchema`, `KNOWN_TYPES`, exports, dispatch, Dart
models/parser, and heavy/status classification. Mirror checkout-variable types
in both languages. New RPCs need the same checkout resolution and deletion checks
as other checkout-scoped terminal operations, plus requester-only responses.

Subscribe before enabling a display writer. Unsupported peers receive an upgrade
status. A timeout is an attachment failure; recovery retires the attachment,
cancels pending work, and establishes a fresh frame baseline.

### Delivery and backpressure

Per-subscriber delivery replaces broadcast terminal display at the outbound
boundary. Internal bus consumers and terminal-owner/checkout ID rewriting remain.

Use a bounded credit window per viewer, with both frame-count and byte limits,
plus a 2 MiB connection-wide terminal budget. At most four unacknowledged frames
and 1 MiB of encoded frame payload are allowed per viewer. Existing transport
credit windows are unchanged.
Reject unsupported geometry or an oversized frame explicitly, without cropping.

- Keep a dirty revision instead of a FIFO of unsent serialized screens. When
  capacity returns, capture/send the newest state. Coalesce before encryption and
  fragmentation; ciphertext already sent cannot be replaced.
- Resolve socket delivery separately from application acknowledgment. Existing
  scheduler send completion does not mean the app parsed or displayed the frame.
- Acknowledge after the app has consumed the frame into its bounded display
  pipeline. It may discard superseded independent frames before parsing; a
  cumulative acknowledgment then retires those too. Measure actual paint
  separately, rather than describing an acknowledgment as proof of rendering.
- Validate acknowledgments against the current attachment and sent high-water
  mark. Ignore duplicates; reject impossible future acknowledgments.
- Preserve ordered input, lifecycle, RPC, and notification delivery. Bound and
  fairly schedule terminal payloads so multiple active terminals and history
  pages cannot monopolize the existing control queue. Do not change relay framing
  or E2E encryption to obtain this behavior.
- On pause, disconnect, revocation, or attachment replacement, retire pending
  viewer work. Recheck delivery authorization immediately before sending.
- Bound acknowledgment waits. A stuck viewer enters a visible recovery state and
  reattaches; it does not cause an ever-growing queue or periodic raw fallback.

Twenty FPS is a ceiling, not a constant rate. A one-frame acknowledgment window
would limit a 100 ms round trip to roughly 10 FPS. A small window permits higher
rates on ordinary remote links, but bandwidth, parsing cost, and high latency
can still reduce delivery. This is an intentional change from the prototype's
single in-flight send. Bound stale in-flight work as well as unsent work.

### Long history

Build an indexed store of normal-buffer rows as they leave the live viewport.
Capture rows at the parser's scroll boundary, before trimming can lose them; a
poll of the final buffer after a large write is insufficient. Validate this hook
first, including multiple scrolls in one write, scroll regions, clears, and resize.
If xterm requires private access, isolate and version-test that adapter like the
OSC 8 adapter.

Store immutable row IDs, text/style runs, link targets, original width, and soft-wrap
metadata. Preserve archived physical rows at their original geometry in v1;
resizing the live terminal does not rewrite the archive. Archived rows are never
pulled back into the viewport when it grows; new viewport space is blank. Only
live rows participate in resize reflow, and newly ejected rows are archived at
their current width. Define the live/history
boundary at the same parser revision as the frame, so scrolling between them
neither repeats nor skips rows. Honor explicit history clears according to a
documented policy, rather than accidentally retaining cleared rows in the UI.

Serve bounded pages by opaque cursor through the authenticated project stream.
Use a disk index so old-page reads do not replay the entire session or load the
entire recording. Keep a bounded app page cache and virtualize rendering. Retention
can expire a cursor; return the new earliest available boundary explicitly.

The prototype's raw JSONL recording is a useful diagnostic/recovery source, not
the production paging format. Production recording, if retained, needs segmented
files, bounded writes, crash-tail recovery, and explicit byte/age limits. A
serialized display frame is not automatically a complete emulator checkpoint:
parser carry, saved state, and mode stacks must be captured for exact replay.
Do not promise fast replay recovery until that contract is tested. History disk
failure should report unavailable history while preserving valid live viewing.

Use bridge-managed session data paths keyed by run ID, never user-provided paths.
Define local file permissions, retention on stop/restart/delete, and disk-full
behavior. Defaults are 256 MiB per run and 2 GiB per machine. SQLite retains
committed rows and run identities across bridge restarts, until explicit deletion
or eviction. The app cache is bounded by 2,000 rows and 16 MiB, with pages capped
at 200 rows and 256 KiB. A history clear starts a new epoch.

Fullscreen alternate-buffer redraws do not form a scrollback transcript. Keep
normal-buffer history available, and retain the product's structured agent
transcript as the conversation source where supported. Time navigation through
fullscreen recordings is outside this implementation.

### App display, input, and links

- Add a dedicated frame application path to `TerminalService`, with run and
  attachment guards. Frame sequences are scoped to each attachment.
  Reject stale geometry and frames by attachment/order, not by arrival time alone.
- Apply each frame atomically to the native Ghostty controller, without generating
  duplicate scrollback. Use a separate history model/view above the live screen,
  controlled by one external archive-sized scrollbar, normal scroll gestures,
  and a contextual Live action. Indexed seeks replace the bounded cache window
  in either direction; one in-flight request coalesces newer drag targets.
  Normal-buffer browsing joins an immutable screen to its exact history boundary;
  alternate-buffer redraws remain a separate live endpoint. Typing, pasting, and
  quick actions return live before sending input. While browsing
  history or making a selection, maintain a stable viewed revision and bounded
  latest-live state so redraws do not move selected text under the user.
- Preserve the existing geometry-driver policy. Passive viewers render the PTY's
  actual grid without resizing it to their own layout; taking control uses the
  existing resize arbitration. Test mouse coordinate mapping at differing sizes.
- Keep keyboard, paste, mouse, and focus reports on the existing authorized input
  path. Restore all input-affecting modes on every frame. Do not infer that input
  was visibly echoed just because the bridge accepted it; distinguish input
  submission, PTY write, subsequent output, frame consumption, and paint metrics.
- Keep the bridge the sole terminal-query responder. Move state-dependent replies
  to the ordered VT parser boundary so a query observes preceding output, not
  later bytes in the same chunk. Correct cursor/Kitty replies and audit advertised
  features such as grapheme handling. Suppress duplicate Ghostty replies.
- Retain the prototype's native OSC 8 restoration approach behind a small adapter.
  Extend style fidelity and test links after wrapping, Unicode, erasure, buffer
  switches, and repeated frames. Preserve plain-text URL detection too. Use the
  existing link activation/path resolution policy for both live and history links;
  targets remain terminal content, never executable terminal control strings.
- Preserve title, bell, clipboard, and notification behavior through explicit
  event handling. Audit which already have separate channels; add missing events
  with bounded payloads and connection/run-scoped IDs. Do not replay one-shot
  side effects with each serialized frame.

## Implementation sequence

| Step | Deliverable and main locations | Completion gate |
|---|---|---|
| 1. Lock contracts | Protocol schemas and lifecycle/flow-control design; `bridge/src/protocol.ts`, Dart models/classification, handshake capability mirrors | Cross-language fixtures cover negotiation, identity, limits, and stale messages; no production mode change |
| 2. Production VT source | `terminal-screen.ts`, `terminal-session.ts`, `terminal-manager.ts`, `terminal-modes.ts`, `vt-capability-responder.ts`; promote experimental code | Native round trips and ordered query tests pass; history scroll hook proves lossless capture under bursts; no second responder |
| 3. Indexed history | New bridge history store/page handlers and lifecycle wiring | Large-session pages read by index; bounded memory; resize/clear semantics, retention, crash tail, and disk-full tests pass |
| 4. Encrypted viewer delivery | `agent-core.ts`, subscriber/transport adapters including local listener, scheduler integration, Dart handshake/session plumbing | Two viewers with different capabilities/speeds remain isolated; routing, access revocation, E2E, bounded queues, and mode exclusivity pass |
| 5. Flutter live/history integration | `terminal_service.dart`, terminal models/view wrapper, dedicated history components using `app/lib/design/` | Atomic display, hydration/reconnect, input/mouse, links, selection, scrolling, and multi-viewer geometry pass |
| 6. End-to-end qualification | Explicit terminal E2E suites and repeatable performance harness | Real agents and representative mobile/desktop links meet agreed budgets; required native tests execute rather than silently skip |
| 7. Enable and simplify | Coordinated replacement, architecture/protocol documentation, prototype cleanup | Full gates pass; unsupported peers require an upgrade; no legacy display path |

The replacement includes indexed history and the app scrolling experience.
Archived terminal runs survive host restart and are advertised as stopped
terminals; their current screens are restored lazily on subscribe. Persisted
screens and ownership metadata share the retention budget with indexed rows.
The host environment overrides are `ANTGRID_TERMINAL_HISTORY_RUN_BYTES` and
`ANTGRID_TERMINAL_HISTORY_MACHINE_BYTES`, in positive integer bytes. SQLite's
page and journal overhead is outside these payload limits.
Qualification covers relay and loopback independently. The current loopback
transport uses a bearer-token-authenticated local socket, while relay application
traffic is E2E encrypted. A test using `LocalTestClient` does not establish local
encryption. Experimental fixtures use the production frame source.

## Validation and release gates

Correctness fixtures must cover split escape sequences, sustained output with no
natural idle gap, synchronized-output timeout, normal/alternate buffers, resize
races, Unicode combining/ZWJ and wide cells, extended underline styling, cursor
shape, keyboard stacks, application keypad, focus/mouse modes, paste, OSC 8,
ordinary URLs, erased links, and one-shot terminal events.

Integration cases must include disconnect during fragmentation, rekey with queued
data, background/resume, permission revocation, old/new app combinations, stale
acks, same-ID respawn, checkout deletion, two isolated checkouts with matching
terminal names, two viewers of different sizes, final output before exit, and a
history request racing retention. Preserve the final drained frame for stopped
terminals and do not let an old run's late exit retire its replacement.

Run current installed Claude Code, Codex, and OpenCode versions on Windows, macOS,
and Linux where supported; record exact versions and rendering modes. Exercise
startup, long output, edits/diffs, menus, approval prompts, multiline input,
scrolling, resize, detach/reattach, and exit. Synthetic fixtures remain the
repeatable gate; real-agent sessions establish practical compatibility.

Measure against existing raw streaming at representative small and large grids:

- Capture/serialize time, native parse/paint time, and CPU on both sides.
- Input-to-visible-update latency, first attach, reconnect, and final-state delay.
- Actual encrypted bytes, frames sent/coalesced, unacknowledged bytes, and queue age.
- Parser backlog, memory over session duration, indexed history latency, disk growth.
- Zero/50/100/250 ms simulated round trips, bandwidth limits, stalled consumers,
and concurrent terminals/preview traffic.

Hard gates: no mixed display modes, no stale-run paint, no lost retained history
rows, no unbounded queue/cache, no serialization while idle, maximum 20 captures
and sends per second, and eventual correct final state after output stops.
Performance budgets are set from the baseline in step 1 and recorded before
rollout; full frames are not assumed to save bandwidth. If the agreed latency or
bandwidth budget fails, tune cadence/window, payload size, and existing negotiated
compression before considering a separately versioned differential protocol.

Use workspace test scripts, scoped native Flutter tests with `-j 2`, bridge
typechecking, the Dart relay-client suite when its handshake changes, and the
explicit E2E command. Run `flutter analyze` once as a serial gate, never alongside
another Dart/Flutter analyzer. Run `npm run check:font-tokens` for the history UI.
Update scoped `CLAUDE.md` files in the change that invalidates their terminal or
capability invariants, and update `docs/architecture.md` and protocol documentation
to describe the final implemented contract.

## Repeatable qualification

Run from the repository root:

```powershell
bun run --filter antgrid-bridge qualify:terminal-frames
```

The runner executes native Ghostty fixtures, the explicit terminal-frame E2E
suite, and the production source/delivery/history benchmark. Phases can be run
independently with `--phase=native`, `--phase=e2e`, or `--phase=performance`.
Benchmark JSON reports are written to `.tmp/terminal-frame-qualification/` or
the directory passed with `--output`. The performance matrix uses 0/50/100/250 ms
acknowledgment delays with unlimited and 256 KiB/s simulated links. These are
simulated delivery conditions, not measurements of a physical network RTT.

Native fixtures cannot skip when the native library is missing. The desktop
packaging workflow executes them on Windows, macOS, and Linux before producing
artifacts. A host fixture run does not certify an iOS/Android renderer.

The benchmark records actual AES-GCM application-envelope bytes for both frames
and a diagnostic model of the removed streaming batcher. Route headers and
fragmentation are excluded, so these numbers are not complete relay wire costs.
It also records capture duration, capture/send rates, frame age at simulated-link
handoff, history page latency/retention, process RSS and CPU, and a sampled parser
queue peak. The CPU total includes the diagnostic baseline; queue sampling can
miss brief peaks. JSON `measurementScope` restates these limits.

Automated hard gates cover the 20 FPS ceiling, idle serialization, continued
delivery, oversized displays, final-state convergence, and history retention.
The benchmark currently uses 500 ms maximum active-output send gaps, 50 ms
history-page p95, and a 2 s final-state drain budget. These are explicit harness
limits, not measured product guarantees. Constrained links may fail the gap or
drain budget and require tuning before release; reducing the frame rate itself
is allowed.

Release evidence must separately include native paint and input-to-paint latency,
actual fragmented relay bytes, concurrent terminal/preview fairness, and exact
Claude Code/Codex/OpenCode versions and exercised flows on supported hosts.
The synthetic benchmark and Node PTY E2E suite do not establish those results.
Do not mark cross-platform real-agent qualification complete from these commands.

## Workspace validation, 2026-09-12

The Windows bridge suite passed with platform-specific skips. The explicit
terminal-frame E2E suite passed over loopback and encrypted relay transports,
including final-frame consumption, same-ID respawn, and stalled-viewer recovery.
The Dart relay-client suite, serial Flutter analysis, bridge/eval typechecking,
and the font-token check passed. Affected Flutter
service/widget suites and native Ghostty fixtures executed successfully after
the remote-recovery changes, including missing-terminal retention, late session
replies, project switching, and checkout cleanup. The encrypted E2E suite also
checks session listing and managed-checkout deletion beside a deliberately slow
frame consumer, including bounded delivery and final-screen consumption.

The complete eight-condition performance matrix passed after making the
simulated link serialize sends and wait for initial attachment delivery before
measuring idle behavior. Reports are generated by `qualify:terminal-frames
--phase=performance`; their measurement-scope limits above still apply.

These checks do not establish the unfinished loopback encryption, real-agent
host matrix, actual fragmented relay byte costs, concurrent terminal/preview
fairness, or input-to-paint latency. Flutter coverage here is the affected suites,
not an app-wide test sweep.
