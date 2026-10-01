# Native desktop app preview — implementation plan

**Date:** 2026-08-01
**Status:** Plan. Not started. Windows-first; macOS gated on an unresolved risk (findings §7).
**Findings this builds on:** [2026-08-01-native-app-preview.md](2026-08-01-native-app-preview.md) — read §3 (capture) and §4 (input) first; this plan does not restate them.

**Goal:** a user picks one native desktop window on their machine and streams it into the Antgrid previewer from another device, with mouse and keyboard control.

> **Status in this repo (2026-09-30).** Written against an older internal codebase and kept as history. Where the body disagrees with this note, the note wins; passages it overturns are marked *(superseded — see status note)*.
>
> - **Signalling rides Iroh project streams, peer-addressed.** `bridge/src/screen-relay.ts` stamps `viewerId` on every viewer→host `screen:*` frame from the viewer's lease-authenticated peer id and delivers it to the loopback owner only. The host must put `viewerId` on every frame it sends; the bridge drops unaddressed ones and delivers addressed ones to that one peer. No broadcast and no echo back to the sender, so neither side does echo suppression. The bridge pushes the lifecycle ends itself: `screen:stop{reason: "viewer-gone"}` to the host when a viewer's session closes, `screen:state{status: "no-host"}` to viewers when the host disconnects, and on screen-control or remote-access revocation `screen:stop` to the host plus `screen:state{status: "ended"}` to the viewer.
> - **The TURN seam was removed.** TURN was never provisioned; ICE is STUN plus host candidates only (`app/lib/services/screen_ice_config.dart`). Off-LAN sessions that hole punching cannot connect are the target of a planned spike tunnelling ICE-TCP through an Iroh stream.
> - **iroh-live (n0's Media-over-QUIC) was evaluated and deferred.** Revisit when it runs on Windows, supports single-window capture, and has a tagged release. Media sits behind `ScreenShareBackend` / `ScreenViewBackend` (`app/lib/services/`), so it can drop in without touching the services or UI.

---

## 1. Architecture — the one decision that shapes everything

Capture and injection live in the **Flutter desktop app**, not the bridge (findings §1: macOS TCC). But the relay only routes *phone ↔ bridge*. So signalling has to cross from the remote viewer to a process the relay cannot address: *(superseded — see status note)*

```
viewer app  --sealed relay stream-->  bridge  --loopback socket-->  desktop app
                                    (opaque relay)                  (capture + inject)

viewer app  <=========== WebRTC media + input datachannel ===========>  desktop app
                        (P2P; never touches relay or bridge)
```

The desktop app is already the bridge's loopback **owner** — it connects to `LocalListener`, subscribes to the project bus, and its frames dispatch with `source: "loopback"` (`bridge/src/local-listener.ts`). So the transport exists. What does not exist is a way to move a frame from the relay side to the loopback side.

### Do not re-publish relay frames onto the bus *(superseded — see status note)*

The obvious implementation — take a relay-sourced `screen:*` frame and `bus.publish()` it so loopback subscribers see it — **is wrong and will echo**. `MessageBus.publish()` fans out to *every* subscriber (`message-bus.ts`), and the relay stream is itself an additive bus subscriber (`stream-mux.ts` `attachStream`, wired in `project-core.ts` `attachRelayStream`). Re-publishing a frame that arrived from the viewer sends it straight back out to the viewer.

Host→viewer is the direction the bus already models correctly: the host publishes, the stream subscriber delivers it outbound. Viewer→host needs **targeted delivery to the loopback owner**, bypassing the bus:

- Intercept in `bindLoopback` (`bridge/src/project-core.ts`). It owns the `LocalListener` instance (`this.listener`) and **both** `startLocal` and `startRemote` call it — see §3 Phase 2 for why that matters.
- Capture the existing `bus.inboundHandler`, install a wrapper that consumes `screen:*` and falls through for everything else. This is the same interception shape `createRelayPromotion` already uses in `startLocal`.
- A relay-sourced `screen:*` goes to `listener.deliver(msg, channel)` directly. A loopback-sourced `screen:*` goes to `bus.publish()` — outbound to the stream, which is what we want.

**Ride the project stream, not the control plane.** Signalling is per-project like `PreviewService`, so it inherits `ProjectSession` lifetime, welcome-replay safety, and the existing `mayDeliver` gate. The window belongs to a machine rather than a project, which argues for the control plane — but that would need its own lifecycle and gating from scratch. Revisit only if we ever want screen sharing with no project focused.

### Three security consequences that are easy to miss

**The bridge can read the SDP.** The E2E seal is app↔bridge, not app↔app. That is acceptable — the bridge runs on the same machine as the capture host, under the same user — but it means signalling is *not* end-to-end between the two app processes, and the plan should not claim otherwise. What the sealed channel does buy is authenticity: carrying the **DTLS fingerprint inside it** binds the media session to the already-authenticated handshake and closes signalling MITM at the relay.

**The input datachannel is invisible to `mayDeliver`.** Every existing remote capability is gated per-frame at the stream's `mayDeliver` hook. A WebRTC datachannel bypasses the bridge entirely, so flipping a switch off would *not* stop remote input. The host must therefore hold a live subscription to both policies and **tear down the `RTCPeerConnection` on revocation**. This is a hard requirement, not a nicety: without it the machine-wide kill switch silently fails to kill the highest-privilege capability in the product. Teardown — not frame gating — is the real enforcement point for this feature.

**`mayDeliver` cannot express a per-capability switch as it stands.** Its signature is `mayDeliver?: () => boolean` (`stream-mux.ts`) — it receives no message, and it guards both the bus subscriber and `sendTunnel`. It is currently wired to `remoteAccessEnabled` alone (`project-core.ts` `attachRelayStream`). *(superseded — see status note)* So there is no way to AND in a screen-specific switch without also gating terminal, tree and git on it. Two options, decided in Phase 1:

- **Widen the signature** to `(msg: AbMessage | null) => boolean`, passing the frame for bus deliveries and `null` for the tunnel path. Fail-closed at the transport, consistent with how the remote-access switch is enforced in both directions — but it touches a shared chokepoint every project stream runs through.
- **Gate at the interceptor** in `bindLoopback` instead: refuse to publish outbound `screen:*` while the switch is off. Smaller blast radius, but it is a gate at the producer rather than the transport, so a future outbound path could miss it.

Prefer the first. Whichever is chosen, it is a *defence-in-depth* layer over the peer-connection teardown, never a substitute for it.

---

## 2. Protocol (`screen:*`)

Per the repo convention, each new type needs **all five**: schema → `AbMessageSchema` union (`bridge/src/protocol.ts:1367`) → `KNOWN_TYPES` (`:1678`) → exported type (`:1493`) → dispatch. `KNOWN_TYPES` is load-bearing on the loopback path specifically: `LocalListener.handleFrame` parses with `parseMessageFast`, which drops anything not in that set.

| Type | Direction | Payload |
|---|---|---|
| `screen:request` | viewer → host | `{projectId}` — asks the local user to start a session. **Never carries a window id.** |
| `screen:state` | host → viewer | `{status: idle\|no-host\|awaiting-consent\|live\|ended, reason?, windowTitle?, width?, height?}` |
| `screen:offer` | host → viewer | `{sdp, dtlsFingerprint, width, height}` |
| `screen:answer` | viewer → host | `{sdp, dtlsFingerprint}` |
| `screen:ice` | both | `{candidate, sdpMid, sdpMLineIndex}` |
| `screen:stop` | both | `{reason}` |

**No enumeration verb, by design** (findings §6). The remote peer may *request* a picker; the local user chooses the window. A `screen:sources` message would be a screen-scraping primitive over the network — do not add one, even for debugging.

> **Superseded 2026-08-04.** Host-only picking makes the feature unusable for its actual case: nobody is sitting at the machine being controlled. `screen:windows` / `screen:pick` were added, and the request carries a `chooser`. The bound that replaced "no enumeration" is narrower but real — the catalog is published only in answer to a `chooser:"viewer"` request, only while the screen-control switch is on, carries **titles and no thumbnails**, and a pick is honoured only against the catalog the host last published.

**`no-host` is not a cosmetic state.** If the desktop app is not connected, `LocalListener.deliver()` returns early with no owner socket and the frame is silently discarded — the viewer would wait forever with nothing to time out against. The interceptor must answer a `screen:request` with `screen:state{status:"no-host"}` when `listener.hasOwner` is false.

Input is **not** a protocol message. It travels on the `RTCDataChannel` as `{t:"mouse"|"key", ...}` — see Phase 4.

Mirrors: Zod in `packages/antgrid-wire` is the source of truth for relay envelopes only; these are agent messages, so `bridge/src/protocol.ts` plus hand-written Dart in `app/lib/models/`.

---

## 3. Work breakdown

### Phase 1 — Screen-control policy *(no dependencies; start here)*

Policy comes first because Phase 2's gating needs a switch to gate on.

New `bridge/src/screen-control-policy.ts`, modelled directly on `remote-access-policy.ts` (same store shape, same fail-closed-on-unreadable-bytes discipline, same "bridge is the only writer, no watcher" stance). Separate file, separate boolean: remote *terminal* control must not imply remote *screen* control. No migration path — unlike remote access there is no v1 state to derive from, so a fresh store starts at `false`.

- Default **off** on a fresh install.
- Loopback callers exempt, matching `currentPhoneAllowed()`.
- Setter verb over loopback only. ~~re-advertise on change~~ — landed without it: nothing in `agent:projects` or the account device record derives from this switch, so the re-advertise `mobile-access:set` does would be a no-op send.
- Flipping off must **immediately** invoke a teardown callback (§1).
- Decide the `mayDeliver` question from §1 here, since Phase 2 consumes the answer.

**Done when:** unit tests cover default-off, toggle persistence, torn-file fail-closed, and revocation firing the teardown callback.

### Phase 2 — Protocol + loopback relay *(blocks 3–5)*

1. `screen:*` schemas in `bridge/src/protocol.ts`, all five touchpoints.
2. Dart mirrors in `app/lib/models/screen_models.dart`.
3. Interceptor in `bindLoopback` (`bridge/src/project-core.ts`) per §1 — targeted `listener.deliver()` for relay→loopback, `bus.publish()` for loopback→relay, `no-host` reply when there is no owner. *(superseded — see status note)*

   **Put it in `bindLoopback`, not in `startLocal`'s promotion wrapper.** That wrapper is local-mode only; `startRemote` never runs it. A project a phone cold-started runs in remote mode and *still* has a loopback owner, because both modes call `bindLoopback` — placing the interceptor in the wrapper would silently break exactly the remote-first case this feature exists for.
4. Gate relay-sourced `screen:*` on remote access **and** the Phase 1 switch. The existing chokepoint is `agent-core.ts` `attachTransport`, whose gate reads `source !== "loopback" && !currentPhoneAllowed()` — note that `currentPhoneAllowed()` itself keys off the presence of a peer pubkey, not off `source`; the `source` check in front of it is what distinguishes the two planes. The new interceptor sits ahead of that handler, so it must apply the equivalent check itself rather than assume it inherits one.
5. Unknown or unhandled `screen:*` must not crash the core.

**Done when:** a `screen:request` from a relay peer reaches the loopback owner **and is not echoed back to the relay peer**; it is dropped when either switch is off; and it answers `no-host` when the desktop app is absent.

### Phase 3 — Capture host (Flutter desktop) *(parallel)*

Add `flutter_webrtc` to `app/pubspec.yaml`. **Verify all six platform builds still succeed before writing feature code** — this is a large native dependency and iOS/Android are not in scope but must not break.

`app/lib/services/screen_share_service.dart`, per-project, `fromSession(session)` following the existing services in `app/lib/services/`, subscribing in the constructor for welcome-replay safety.

- Host role: enumerate via `desktopCapturer.getSources(types: [SourceType.Window])`, capture via `getDisplayMedia({deviceId:{exact:id}})`.
- **Apply the findings §3 tuning immediately** — `MAINTAIN_RESOLUTION` + `maxBitrate: 8_000_000` + `minBitrate: 1_000_000`. Defaults give 362×225, which is unreadable and would read as "the feature doesn't work".
- Thumbnails arrive asynchronously; the picker must subscribe to `onThumbnailChanged`, never read `thumbnail` synchronously.
- Minimised windows are not enumerable and collapse a live capture to 1×1 — detect and surface as a real error state, not a black rectangle.
- Session ends when the window closes, the policy flips, or the peer disconnects.

### Phase 4 — Input injection (Windows) *(parallel)*

`app/lib/native/win32_input.dart` — liftable from the spike at `C:\Users\Admin\Documents\wgc_spike\lib\win32_input.dart`, minus the spike-only helpers. Hand-rolled `dart:ffi`, **not `package:win32`** (its `INPUT` union layout moved between major versions). No native plugin, no C++ in the build.

Behind `app/lib/native/input_injector.dart` (abstract) so macOS can land later without touching callers.

- Raise **once per session**, not per event (findings §4) — per-event raise-and-restore thrashes the local user's focus.
- Backgrounded raise needs `AttachThreadInput`. Run it **off the UI thread with a timeout**: attached input queues can block if the target stops pumping messages, and on the platform thread that freezes Antgrid.
- Verify the target is foreground before every `SendInput` batch. It is system-wide; injecting into the wrong window types into the user's real apps.
- Elevated targets are permanently unreachable (UIPI, and Store MSIX can never set `uiAccess`). Detect and show a clear error.
- Datachannel: unordered/unreliable for mouse-move, ordered for clicks and keys. The spike measured ordered at 1.4–2.4 ms median, so this is a jitter choice, not a throughput one.

**Coordinate mapping is an open input, not a solved one.** Scale is exactly 1.0 at 100% display scaling; the origin offset matches neither `GetWindowRect` nor DWM bounds. Resolve it from libwebrtc's cropping source before shipping — do not calibrate at runtime, since a product cannot click twice in the user's app to find out where its own pixels are. Characterise at non-100% scaling too, where a non-unit scale would appear. **This research has no code dependency — start it at Phase 1, not here** (§5).

### Phase 5 — Viewer + picker UI *(parallel)*

- Window picker: local UI on the host, built from `AbDialog` / `AbListRow` / `AbButton`. **No Material widgets, `AbIcons.*` not `Icons.*`, `AbTokens` not literals.** Run `npm run check:font-tokens`.
- Viewer surface in `app/lib/screens/preview_screen.dart` alongside the existing HTTP-tunnel preview — a mode, not a replacement.
- Explicit states for every `screen:state` status, including `no-host` and the minimised-window error.
- Pointer/keyboard capture translating viewer-local coordinates → frame coordinates, sent over the datachannel.
- Mind `app/lib/screens/workspace_shell.dart`'s `GlobalKey` reparenting contract — a panel-mode toggle must not tear down a live peer connection.

### Phase 6 — Transport hardening *(start as soon as Phase 3 has a live stream)*

Not an end-of-project polish phase — ICE behaviour on a real network is a risk to retire early, because it can invalidate the transport assumptions the viewer UI is built on.

- ICE: host candidates first (LAN needs no infrastructure), STUN, then managed TURN. *(superseded — see status note)*
- Verify the DTLS fingerprint from the sealed channel against the negotiated one; abort on mismatch.
- Measure on a real LAN and over cellular, not loopback.

### Phase 7 — macOS *(gated)*

> **Updated 2026-08-10.** Findings §7 item 1 is now answered, and it answered
> badly: neither flutter_webrtc nor the libwebrtc it ships has any SCK **window**
> path, so window capture lands on `CGWindowListCreateImage`, `obsoleted=15.0`.
> It still returns pixels on macOS 26.4, so this is not an emergency — but it is
> not a foundation either, and there is nothing upstream to migrate onto.
> **Phase 7 therefore starts with building the SCK window path, not with
> measuring the old one.** Scope is smaller than "a native plugin": add
> `initWithDesktopIndependentWindow:` beside the existing display filter in
> `FlutterScreenCaptureKitCapturer.m` (~150 lines today, already feeding
> `RTCVideoCapturer`) and route window sources to it. Upstream it rather than
> forking.

Item 2 is partly settled and is the *cheaper* half: the `CGEvent` family is
undeprecated and `CGEventPostToPid` offers per-process delivery with no Windows
equivalent, so **measure per-pid delivery before backgrounded activation** — if
it lands, nothing needs raising and the activation risk mostly evaporates.
`activateWithOptions:` is likewise not deprecated in the 26.4 SDK.

**Both halves need a machine where TCC can actually be granted**, which is the
real gate on this phase. SCK returns nothing at all without Screen Recording —
not even the caller's own window — and no synthetic event is delivered without
Accessibility. An Apple Development signature is enough to register for those
grants (findings §7 item 9); ad-hoc is not.

---

## 4. Testing

| Layer | Command | Covers |
|---|---|---|
| Bridge | `bun run --filter antgrid-bridge test` | protocol round-trip, relay→loopback delivery, **no echo back to the relay peer**, `no-host` reply, both policy gates, revocation teardown |
| App | `cd app && flutter test` | service state machine, coordinate transform, picker widget |
| Analysis | `flutter analyze` (once, from the controller — **never concurrently**) | CI-equivalent gate |
| Fonts | `npm run check:font-tokens` | design-system compliance |

Skip the E2E eval harness unless signalling proves flaky — it spawns real agents, relays and PTYs, and this feature's risk is concentrated in native capture and injection, which evals cannot exercise.

**Two tests worth writing before the feature works:**

1. Revoking either policy mid-session tears down the peer connection. It is the only assertion standing between the kill switch and a remote peer retaining input after being cut off.
2. A relay-sourced `screen:*` frame reaches the loopback owner and does **not** appear on the outbound stream. The echo is invisible in manual testing — signalling still completes — so only a test catches it.

---

## 5. Sequencing for a workflow run

```
Phase 1 ── Phase 2 ──┬── Phase 3 ──┬── Phase 6 ── Phase 7 (gated)
                     ├── Phase 4 ──┤
                     └── Phase 5 ──┘

(coordinate-mapping research: runs alongside Phase 1 onward, no code dependency)
```

Phase 1 has no dependencies and unblocks Phase 2's gating. Phases 3–5 fan out after Phase 2. Phase 6 starts as soon as Phase 3 produces a live stream rather than waiting for 4 and 5.

Phase 4's coordinate-mapping research is the item most likely to force rework if left late, and it needs no code — put it in the first fan-out.

Rough effort, Windows only: Phase 1 ~1 day, Phase 2 ~2 days, Phase 3 ~3 days, Phase 4 ~2 days, Phase 5 ~3 days, Phase 6 ~2 days. macOS adds ~4 days if capture passes, considerably more if it does not.

---

## 6. Risks carried into implementation

| Risk | Impact | Handling |
|---|---|---|
| `AttachThreadInput` is an unsanctioned workaround | Remote input silently stops working after a Windows update | Isolate behind one function; consider requiring Antgrid foreground at session start |
| Frame-origin offset unresolved | Clicks land a few px off target | Resolve from libwebrtc source; likely tolerable for buttons, not for precise UI |
| Widening `mayDeliver` touches every project stream | A regression here breaks terminal/tree/git delivery, not just screen | Decide in Phase 1; if taken, cover the tunnel (`null`) path in tests |
| macOS backgrounded activation may be impossible | Reshapes the feature on macOS | Measure before any macOS build work |
| libwebrtc binary size | DMG/MSIX budget | Measure at Phase 3 dependency add, before feature code |
| Software VP8 encode only | ~29% of one core per session | Accepted for v1; revisit if concurrent sessions are wanted |
