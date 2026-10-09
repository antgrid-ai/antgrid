# Terminal clipboard sharing

Status: Accepted; implementation qualification in progress

Date: 2026-10-09

Scope: Terminal copy/paste actions only. Continuous OS clipboard synchronization is excluded, as agreed.

The accepted v1 defaults use a five-second ownership window, 100,000-byte text limit, burst-three writes with one token per second, 250 ms duplicate suppression, and a two-second host-read timeout. Overlapping viewers pause program copies. Mobile selection starts with Select text. Program copies default on with a device-local opt-out.

## Outcome

Copying terminal text should put it on the clipboard of the device the user is operating. Local and remote sessions should have the same selection controls. Guest terminal applications should retain their mouse interactions and shortcuts.

Provide three paths:

1. Reliable local text selection, including Shift+drag and a visible Select text action.
2. OSC 52 writes from a running terminal program, delivered to one authorized, actively interacting viewer.
3. An explicit remote action, **Copy host clipboard to this device**, for programs that only write the host OS clipboard.

Opening a session, subscribing, reconnecting, or replaying history must never change a clipboard. There is no clipboard polling, continuous synchronization, or automatic local clipboard read.

## Evidence and root cause

The reported remote live-screen interaction changes the host clipboard but leaves the viewing device clipboard empty. Local sessions work, and Shift+drag works remotely. The exact guest program and version used in the reproduction still need recording.

This establishes a selection-ownership difference: normal drag can belong to the terminal application when mouse reporting is enabled, whereas Shift+drag selects in the viewer. A host clipboard change alone does not establish whether the program also emitted OSC 52.

Repository findings:

- `app/lib/widgets/terminal_view_wrapper.dart` uses the terminal engine's automatic mouse policy. Its app selection copy writes Flutter's local clipboard. History shortcut handling differs from the live view. Live frame replacement clears selection, and the existing agent-running Ctrl+C shield also catches Ctrl+Shift+C without local selection.
- The installed Ghostty Flutter engine forwards normal pointer interaction when terminal mouse reporting is active; Shift bypasses it. Its copy shortcut matcher uses Cmd+C on macOS and Ctrl+Shift+C elsewhere.
- `bridge/src/terminal-session.ts` feeds live PTY output into logging and batching. `bridge/src/terminal-manager.ts` feeds the terminal screen. `bridge/src/terminal-frames/source.ts` serializes screen state, with no clipboard event channel.
- App subscribers receive terminal frames rather than raw `terminal:output` through `bridge/src/message-bus.ts`. The viewing terminal therefore cannot reliably discover transient OSC commands from live frames.
- `app/lib/services/terminal_service.dart` paints replacement frames into the viewing engine. It does not forward host clipboard side effects.

A minimal probe using the installed xterm headless parser and serializer observed the OSC 52 payload `c;aGVsbG8=` while the serialized screen contained no OSC 52 sequence. This confirms the transient-command loss at serialization; it is not an end-to-end test of an actual agent or device clipboard.

The missing architectural component is a live, targeted clipboard event path independent of screen serialization. Native-only guest copies additionally require an explicit host clipboard read or future agent integration.

## Standards and agent compatibility

OSC 52 is a terminal escape command for clipboard operations. It is not OS clipboard synchronization. Terminal selection and guest-program selection are separate interactions. See [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html), [Ghostty OSC 52](https://ghostty.org/docs/vt/osc/52), [Ghostty Shift mouse handling](https://ghostty.org/docs/vt/csi/xtshiftescape), and [Windows Terminal selection](https://learn.microsoft.com/en-us/windows/terminal/selection).

| Program | Current primary-source evidence | Consequence for Antgrid |
| --- | --- | --- |
| Claude Code | Fullscreen selection copies on release by default. Documented clipboard paths include native utilities, SSH OSC 52, and tmux integration. | A host clipboard change may occur before Ctrl+C. Do not assume a non-SSH Antgrid PTY emits OSC 52. |
| Codex CLI | Current upstream copy code tries native clipboard access. SSH/tmux paths also forward through the terminal; other environments use terminal forwarding as a native-copy fallback. | Native copy succeeding on the host can prevent OSC 52 emission outside the detected environments. |
| OpenCode | Current development source writes OSC 52 when stdout is a TTY, then attempts native clipboard copying. It includes direct and tmux passthrough forms. | OSC 52 is a promising primary path, but duplicates and actual released versions must be tested. |

Sources: [Claude fullscreen](https://code.claude.com/docs/en/fullscreen), [Claude remote clipboard troubleshooting](https://code.claude.com/docs/en/troubleshooting#copied-text-doesnt-reach-your-local-clipboard-over-ssh), [Codex clipboard implementation](https://github.com/openai/codex/blob/main/codex-rs/tui/src/clipboard_copy.rs), [OpenCode clipboard implementation](https://github.com/anomalyco/opencode/blob/dev/packages/tui/src/clipboard.ts), [OpenCode release restoring direct OSC 52](https://github.com/anomalyco/opencode/releases/tag/v1.1.51).

These are source-level findings from the specification review, not guarantees for every installed version. Do not fake SSH environment variables, disable host clipboard utilities, or restart existing sessions to influence these programs. Attaching a remote viewer after a process starts must still work.

## Interaction design

### Selection owned by the viewer

Normal mouse behavior stays automatic so TUIs remain usable. Shift+drag bypasses guest mouse reporting. Add **Select text** to terminal controls/context actions and a discoverable hint: **Hold Shift to select text locally**.

Local selection must use a stable, immutable snapshot of the currently displayed screen, captured at pointer-down for Shift+drag or when entering Select text. Render it as a read-only selection surface while the underlying live terminal continues receiving frames. Display **Selecting text · Esc to return** and **Return to live**. Snapshot coordinates must never refer to a later frame.

Copy success returns to live. Escape, Return to live, run replacement, session switch, or leaving the terminal exits selection. Typing exits and forwards the initiating input once. Snapshot gestures must not emit guest mouse reports. A failed clipboard write preserves the selection and offers retry.

Use the same behavior in live and history views:

| Platform | With viewer-owned text selected |
| --- | --- |
| Windows | Ctrl+C and Ctrl+Shift+C copy |
| Linux | Ctrl+Shift+C copies; preserve the existing Ctrl+C selection alias |
| macOS | Cmd+C copies |

The visible Copy action always works. Without viewer selection, Ctrl+Shift+C must reach the guest. Preserve the existing bare Ctrl+C agent-interrupt policy; redesigning that policy is outside this spec. The app cannot infer a guest application's internal selection merely from its screen.

### Phone and tablet interaction

Copy from a remote terminal to the viewing phone or tablet is included. The destination is that device's OS clipboard, so the user can paste the copied text into another app. Copying on one phone must not update other viewers' clipboards.

Touch users must not depend on Shift+drag or a hardware keyboard. Expose Select text in the terminal action menu. Entering it freezes a viewer-owned screen snapshot and enables touch selection handles, selection adjustment, and a visible Copy action. Provide Return to live; dismissing selection returns to the live terminal. If a long-press shortcut is provided, it enters this explicit selection mode without also forwarding a guest mouse gesture. Normal touch behavior outside selection mode retains the terminal's existing scrolling and guest interaction policy.

Guest OSC 52 copies use the same foreground ownership and acknowledgement rules on phones. A background app or passive viewer cannot receive a clipboard mutation. The explicit Copy host clipboard to this device action is available on remote phone/tablet sessions as well as desktop sessions.

Mobile Paste is an explicit terminal action that reads the phone's clipboard and uses the existing text/image paste pipeline. Merely opening or focusing a terminal must not read the clipboard. Handle Android/iOS platform restrictions and failures through actionable feedback without claiming success. Validate touch selection under streaming output, copy into another mobile app, paste back into the remote terminal, background/reconnect behavior, and platform clipboard feedback on real devices.

### Selection owned by the guest

An eligible OSC 52 write updates the viewing device clipboard. Show **Copied** only after the platform write succeeds. Respect guest copy-on-select behavior; do not add a second automatic copy on every mouse release.

If the guest only writes the host OS clipboard, expose **Copy host clipboard to this device** in remote terminal actions. It reads host text once on explicit request. Keep it separate from Copy selected text because the host clipboard may contain older or unrelated content. Hide it for local sessions. Empty, unsupported, oversized, or failed reads leave the viewing clipboard unchanged and report the reason without exposing content.

### Paste

Preserve existing paste shortcuts, text handling, bracketed paste, and image upload behavior. Paste reads the viewing device clipboard only in response to the user's paste action. OSC 52 clipboard reads are not supported in v1.

## Live OSC 52 extraction

Implement a per-PTY bounded streaming scanner at live ingress in `terminal-session.ts`, before raw debug logging and before batching or dropping output. Do not extract from saved frames, serialized screens, archives, history, or viewer reparsing.

The scanner must handle sequences split across chunks, BEL and ST termination, cancellation, overflow recovery, and unrelated OSC/DCS/APC/PM/SOS strings. Specify behavior for C1 controls according to the actual PTY decoding. Avoid per-chunk regex extraction and unbounded accumulation.

Accepted v1 policy:

- Accept clipboard selectors empty, `c`, `s`, and `p`, mapping supported selections to the viewing device's system text clipboard. A supported selector list causes one write. Ignore unsupported-only selections and cut buffers.
- Validate base64 strictly and require valid UTF-8 text without NUL. Preserve tabs and newlines. Ignore empty/malformed writes; v1 does not remotely clear the clipboard.
- Limit decoded text to 100,000 bytes, base64 to 133,336 characters, selector text to 16 characters, and the complete encoded clipboard event to 140 KiB. Enforce bounds on both endpoints before large allocation.
- Apply a per-run token bucket: burst three, refill one per second. Keep at most one pending program write per recipient/run. Coalesce rejection feedback and never block PTY rendering.
- Require direct OSC 52 support. Support a single bounded, exact tmux passthrough wrapper with fixtures. Deduplicate direct/wrapped duplicates using a short-lived content digest within the same recipient epoch, window 250 ms. Do not log the digest or text.
- Do not advertise GNU screen passthrough until its actual framing passes qualification.
- Deny `?` read requests without reading either OS clipboard. Return a bounded empty OSC 52 response with matching supported selector and terminator. Do not wait for app permission or a remote clipboard response.

These limits are accepted defaults, subject to qualification. The scanner should expose only sanitized events and reasons to other subsystems.

## Recipient ownership and authorization

Clipboard content must never broadcast to terminal subscribers. Subscription, resize, passive focus, or being online does not establish ownership.

Use an explicit short-lived clipboard claim bound to the authenticated `ClientKey`, connection generation, actual project/checkout/terminal address, run ID, and attachment ID. Claims cannot name an arbitrary recipient. Send a claim immediately before dependent user input on the same ordered project stream. The bridge resolves the claim and queues its acknowledgement before writing that input to the PTY; the app does not wait for an extra round trip. Eligible activity includes real guest mouse gestures, keyboard/IME input and explicit terminal Send actions, covering `/copy` without inspecting a reconstructed command buffer. Hover, terminal queries, resize, and passive screen viewing do not acquire claims.

Claim refusal never prevents terminal input. The app must process the claim acknowledgement before accepting a clipboard write on the same ordered project stream. The existing work-status filter for mouse reports must not accidentally discard clipboard ownership signals.

The claim lifetime is five seconds, renewed during an active held gesture within a bounded duration. Revoke on focus loss, backgrounding, stream closure, run replacement, session change, or remote-access revocation. Claims are not durable state.

Snapshot the recipient and claim epoch at the start of an OSC sequence at live ingress. Recheck authorization before delivery and before the app starts a clipboard mutation. A different claimant invalidates the old epoch; never retarget an old event to a new claimant. Drop ambiguous overlapping interactions and provide local selection as the reliable fallback.

OSC 52 does not carry actor identity or a request correlation ID. Claims are an interaction policy, not proof of which user's action caused a delayed guest write. Strict attribution of arbitrary delayed output from simultaneous viewers is impossible with OSC 52 alone. Expired or ambiguous events must fail closed; do not fall back to broadcasting or writing a local desktop clipboard.

## Transport and protocol

Send small clipboard records on the authenticated native project stream, or the existing token-gated loopback control path for a local app. Never use central WebSocket payloads, push delivery, or plaintext remote transport. Clipboard records do not join the terminal/preview bulk stream routing sets.

Introduce a separate clipboard capability/version. Do not bump the terminal screen protocol solely for clipboard events. Old clients receive no clipboard writes. Against old bridges, local selection remains usable and unsupported remote actions stay hidden.

Clipboard records, using the normal validated message envelope:

| Record | Direction | Required context |
| --- | --- | --- |
| `terminal:clipboard:claim` | App → bridge | Request ID, terminal address, run ID, attachment ID |
| `terminal:clipboard:claimed` | Bridge → requester | Matching request, claim ID/epoch, lifetime or refusal |
| `terminal:clipboard:release` | App → bridge | Matching claim/context |
| `terminal:clipboard:revoked` | Bridge → previous owner | Matching claim/context and sanitized reason |
| `terminal:clipboard:write` | Bridge → owner | Event ID, claim/epoch/context, UTF-8 base64 text |
| `terminal:clipboard:result` | App → bridge | Matching event/context; copied, denied, stale, or failed; no text |
| `terminal:clipboard:read-host` | App → bridge | Explicit request ID and current terminal context |
| `terminal:clipboard:host-text` | Bridge → requester | Matching request/context; bounded UTF-8 base64 text or sanitized error |

All records require full validation even on fast parsing paths. Register TS schemas, message union, known types, exports, dispatch, and appropriate checkout-scoped classification; mirror the wire contract and classification in Dart. Resolve the actual owning session checkout rather than trusting client-supplied paths. Reject app-origin records that impersonate bridge-only writes.

Use existing account membership, machine remote-access switch, catalog, and native endpoint authorization gates. Host reads also require these gates and requester-specific routing. Revocation is immediate.

The app needs one clipboard coordinator rather than clipboard side effects in every terminal widget. It validates foreground state, context, claims, and request IDs; serializes terminal clipboard operations; discards stale queued writes; and deduplicates event IDs in bounded memory. Local terminal copies use the same coordinator so newer actions supersede pending program writes. Platform writes already in progress may be uncancellable; document and test ordering rather than promising cancellation after mutation begins.

Acknowledge only after platform success. Catch platform failures, avoid content-bearing errors, and never retry or replay on reconnect. Bridge send success and guest `/copy` success are not proof of a viewing-device clipboard write.

Explicit host reads use platform-specific native backends: macOS, Linux Wayland/X11, and Windows. Use fixed commands or native APIs, never content interpolated into shell commands. The timeout is two seconds with bounded output and helper cleanup. Missing tools and unsupported formats return sanitized errors. Windows helpers must stay hidden.

## Privacy and observability

Program copy is text-only. No background clipboard listener, automatic local clipboard read, OSC 52 read forwarding, or image transfer through OSC 52 is introduced. A device preference may disable program-initiated writes while preserving explicit local copy and explicit host-read actions.

Never persist clipboard payloads in frame history, replay state, caches, telemetry, diagnostic logs, or crash reports. Redact the new record bodies from traffic inspection.

Importantly, `terminal-session.ts` currently logs raw PTY data before screen processing when `ANTGRID_DEBUG_PTY_LOG` is enabled. Filtering only the new wire messages would still leak OSC 52 text. Streaming ingress must redact clipboard sequences before every raw-output diagnostic sink, or suppress the relevant captures when safe redaction cannot be guaranteed. Audit terminal-output inspection as well. Add regression fixtures for split and malformed sequences so logging cannot expose partial payloads.

Diagnostics may record sanitized outcome categories, byte counts, and capability availability. They must not record copied content. User-visible feedback should describe the action without protocol terminology.

## Acceptance and qualification

1. Scanner tests cover chunk boundaries, terminators, cancellations, nested unrelated strings, tmux duplicates, malformed base64/UTF-8, NUL, limits, read denial, overflow recovery, and rate limits.
2. Bridge tests prove a live OSC write with no screen change still creates an event, while archives/history/reconnect create none. Two viewers yield at most one eligible recipient. Cover expired claims, connection generations, intervening ownership, forged context, remote-access revocation, and rejected app-origin writes.
3. App tests exercise actual pointer selection while frames arrive, rather than merely calling a selection callback. Verify stable text, live/history shortcut parity, guest Ctrl+Shift+C passthrough, unchanged bare Ctrl+C shielding, selection retention on failure, and duplicated terminal surfaces producing one clipboard write.
4. End-to-end coverage uses real PTY output over authenticated Iroh with two viewers and a recording clipboard sink. Assert event delivery and successful acknowledgement, loss after revocation, and no replay after reconnect. Automated tests must not mutate a developer's real clipboard.
5. Qualify released Claude Code, Codex CLI, and OpenCode versions. Record program version, renderer, launch environment, native clipboard availability, and whether a raw live OSC event is emitted. Exercise copy-on-select on/off where applicable, guest copy shortcuts, `/copy`, Codex copy actions, native-only copies, tmux, and remote attachment after process launch. Use synthetic text, never real user clipboard contents.
6. Validate Windows, macOS, Linux X11/Wayland desktop behavior and Android/iOS foreground clipboard behavior. Verify existing text/image paste behavior and host-read timeout/empty/unsupported cases.
7. Inspect diagnostics, traffic views, persisted frames, and history fixtures for absence of copied content. Test raw PTY debug logging explicitly.

Use component test scripts, not bare root `bun test`; run Dart analysis serially according to repository instructions. The parser/serializer probe evidence is above; implementation test results and outstanding real-agent and cross-platform gates are recorded in the [qualification report](terminal-clipboard-qualification.md).

## Delivery and remaining decisions

Implement stable local selection and shortcut parity first. Then deliver live extraction, recipient claims, privacy controls, acknowledgement, and the explicit host-read fallback as one coherent remote feature. Native-only copying remains explicit unless a separately qualified agent integration can cause terminal forwarding without changing unrelated environment semantics.

Before implementation sign-off, settle numeric limits through fixtures and measurements, finalize claim conflict behavior, and verify the selected native host-read APIs. Do not promise seamless guest copying for a particular agent version until its actual Antgrid launch path passes qualification. GNU screen support remains unadvertised until tested.

Qualification evidence and remaining platform checks are tracked in [Clipboard qualification](terminal-clipboard-qualification.md). Completion requires the declared acceptance gates; implementation alone does not qualify a platform.
