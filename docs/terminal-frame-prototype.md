# Snapshot-only terminal prototype

This is a local, executable experiment for evaluating terminal frames before
changing Antgrid's app transport. It is not enabled in the bridge host or app.

## Run

From the repository root, run the deterministic PTY demo:

```powershell
bun run bridge/scripts/terminal-frame-prototype.ts --demo
```

In an interactive terminal, the runner paints ANSI frames and forwards keyboard
input to the child. When stdout is redirected, it emits JSON frames. Each frame
includes its originating dimensions; a consumer must apply those dimensions
before the ANSI body. The current runner follows the physical terminal's size.
Use the direct command above for interactive viewing: Bun's workspace filter
captures stdout and prefixes lines, which turns that invocation into JSON output.
From `bridge/`, `bun run prototype:terminal --demo` is also available.

Run a particular CLI with separate arguments after `--`:

```powershell
bun run bridge/scripts/terminal-frame-prototype.ts -- claude
```

The runner prints its history recording path to stderr. Use `--record NEW_FILE`
to choose a path; the parent directory must exist, and existing files are refused.
History contains terminal output, so keep the recording with the session's local
data. Nothing opens a network listener or changes the E2E transport.

Simulate a slow viewer:

```powershell
bun run bridge/scripts/terminal-frame-prototype.ts --demo --json --delay-ms 150
```

Read retained normal-buffer history separately:

```powershell
bun run bridge/scripts/terminal-frame-prototype.ts --history 'PATH_FROM_STDERR' --lines 2000
```

The history command returns plain text from the final normal buffer, including
scrollback. It does not invent a conversation transcript from fullscreen redraws.
The recording retains output and resize events from the start; fullscreen states
can be reconstructed by replay, but the CLI does not yet expose time navigation.

## Data path

`TerminalFrameSource` extends the existing `TerminalScreen`, using its headless
VT and serializer. The prototype enables xterm's Unicode 11 width provider.
Every output chunk goes into the headless VT and a separate local recording.
Only serialized display frames go to stdout; no unparsed PTY tail is appended.

`TerminalFrameDelivery` caps sends at one per 50 ms. It serializes only after
the prior send completes, so the pending work is a revision, not a queue of
outdated screens. Unchanged ANSI and dimensions are not sent. It keeps one
in-flight frame, which can become stale while the viewer consumes it; the next
frame describes the newest state. A future transport adapter must resolve its
send promise at the intended flow-control boundary, not merely upon enqueueing.

Snapshots wait for the headless parser and for DEC 2026 synchronized output to
end. A guest that leaves synchronized output enabled gets a frame after the
prototype's timeout, marked `syncTimedOut`; that frame may be a partial redraw.
Each outgoing body is itself wrapped in synchronized output for the viewer.
Parser overload and oversized frames fail explicitly instead of dropping bytes
and continuing with an untrustworthy screen.

OSC 8 links are extracted from the active buffer's cell metadata. The serialized
screen is followed by styled link spans wrapped in OSC 8 sequences, restoring
native links in Ghostty. The final cursor is placed at an absolute grid coordinate
with full scroll margins, correcting a wide-link cursor mismatch found in the
native test. This currently uses xterm's private link service and
cell attributes; dependency upgrades need the round-trip tests. Cursor and input
modes are restored after the overlay. Kitty keyboard flags are tracked using
parser callbacks and bounded, separate stacks for the normal and alternate
buffers, following the [Kitty keyboard protocol](https://sw.kovidgoyal.net/kitty/keyboard-protocol/).

History recording is independent of frame delivery and the live VT's small
scrollback ring. Writes go directly to an exclusively created local file, without
an unbounded memory queue. Output size determines disk use. The current history
reader replays from the beginning and retains up to 10,000 normal-buffer lines
in its separate emulator; it does not replay the log into the live viewer.

## Validation

```powershell
bun run --filter antgrid-bridge test tests/terminal-frame-prototype.test.ts tests/terminal-screen.test.ts tests/terminal-modes.test.ts tests/vt-capability-responder.test.ts
bun run --filter antgrid-bridge typecheck
```

The same TypeScript compiler can be invoked directly if Bun's command shim stalls
on Windows:

```powershell
bun bridge/node_modules/typescript/bin/tsc --noEmit -p bridge/tsconfig.json
```

Native cross-engine validation, from `app/`:

```powershell
flutter test -j 2 test/terminal_frame_prototype_test.dart
```

This generates frames using the actual TypeScript prototype and feeds them to
the app's native Ghostty controller. It checks screen text, cursor placement,
repeated application, wrapping, representative wide characters, and OSC 8 targets.
It reports a skip if the native library is unavailable.

Real PTY smoke validation, from `bridge/`:

```powershell
bun run scripts/terminal-frame-smoke.ts
```

The smoke runner checks ordinary and delayed delivery, the final screen and link,
and history lines that never appeared in a delivered frame. It retains recordings
in the printed temporary directory for inspection.

A Windows run on 2026-09-10 produced the following results for the deterministic
demo (1,000 log lines followed by 120 small fullscreen updates):

| Viewer delay | Frames | Raw PTY bytes | JSON frame bytes | Elapsed |
|---|---:|---:|---:|---:|
| 0 ms | 36 | 21,866 | 51,300 | 5.12 s |
| 150 ms | 12 | 21,866 | 17,051 | 4.23 s |

Both runs recovered all log lines and reached `Complete`, with no synchronized
output timeouts. These are one-run measurements, not throughput guarantees.
Timing depends on ConPTY batching, parser scheduling, and other machine activity.
Small updates can cost more bandwidth as full frames. The existing serializer
also includes the normal visible buffer while the alternate buffer is active.

## Remaining integration work

- Negotiate a snapshot-only mode per viewer through the existing encrypted
  transport. Preserve checkout routing, authorization, generation checks, input
  echo accounting, and attach lifecycle. No production protocol was added here.
- Add a history index/checkpoints and a separate history view or paged history
  protocol. Replaying a multi-hour log from the beginning is intentionally only
  a prototype implementation. Plan disk retention and crash-tail recovery.
- Validate actual fullscreen agents end to end: input, mouse, resizing,
  selection, reconnect, multi-viewer geometry, and slow mobile connections.
  The synthetic PTY demo does not establish agent compatibility.
- Audit grapheme clusters/ZWJ emoji, extended underline styles/colors, cursor
  shape, graphics, and other terminal extensions. Unicode 11 width parity for
  the tested characters does not establish full Ghostty equivalence. Link
  overpainting currently preserves basic SGR styling.
- Reconcile terminal capability replies with the authoritative headless state.
  The runner reuses `TerminalSession`'s existing responder, including its fixed
  cursor-position and Kitty query replies; keyboard flag restoration alone does
  not fix that query path. Clipboard/title/notification events need their existing
  separate app channels, since display snapshots do not contain those events.

The prototype demonstrates independent live frames, link restoration, bounded
pending delivery, and retained output. It is not sufficient evidence to replace
the production terminal transport yet.
