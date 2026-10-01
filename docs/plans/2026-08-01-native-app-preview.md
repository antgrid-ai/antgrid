# Native desktop app preview — findings, chosen approach, open questions

**Date:** 2026-08-01
**Status:** Research + Windows capture spike + Windows input spike complete. Windows capture and input risks retired. macOS capture measured 2026-08-10 and **fails** (§7 item 1); macOS input injection is unmeasurable without an Accessibility grant (§7 item 2). Not yet a spec.
**Goal:** Let a user pick one **native desktop app window** (Windows/macOS) and stream it into the Antgrid previewer, and interact with it to test their app. Full-desktop streaming is explicitly out of scope.
**Related:** `app/lib/services/preview_proxy_server.dart`, `app/lib/services/preview_service.dart`, `bridge/src/message-bus.ts`, `bridge/src/remote-access-policy.ts`, `infra/tofu/network.tf`, `.github/workflows/build-desktop.yml`

> **Status in this repo (2026-09-30).** Written against an older internal codebase and kept as history. Where the body disagrees with this note, the note wins; passages it overturns are marked *(superseded — see status note)*.
>
> - **Signalling rides Iroh project streams, peer-addressed.** `bridge/src/screen-relay.ts` stamps `viewerId` on every viewer→host `screen:*` frame from the viewer's lease-authenticated peer id and delivers it to the loopback owner only. The host must put `viewerId` on every frame it sends; the bridge drops unaddressed ones and delivers addressed ones to that one peer. No broadcast and no echo back to the sender, so neither side does echo suppression. The bridge pushes the lifecycle ends itself: `screen:stop{reason: "viewer-gone"}` to the host when a viewer's session closes, `screen:state{status: "no-host"}` to viewers when the host disconnects, and on screen-control or remote-access revocation `screen:stop` to the host plus `screen:state{status: "ended"}` to the viewer.
> - **The TURN seam was removed.** TURN was never provisioned; ICE is STUN plus host candidates only (`app/lib/services/screen_ice_config.dart`). Off-LAN sessions that hole punching cannot connect are the target of a planned spike tunnelling ICE-TCP through an Iroh stream.
> - **iroh-live (n0's Media-over-QUIC) was evaluated and deferred.** Revisit when it runs on Windows, supports single-window capture, and has a tagged release. Media sits behind `ScreenShareBackend` / `ScreenViewBackend` (`app/lib/services/`), so it can drop in without touching the services or UI.

---

## 1. Chosen approach

**`flutter_webrtc`, hosted in the Flutter desktop app — not in the Bun bridge.**

| Concern | Decision |
|---|---|
| Capture | `desktopCapturer.getSources(types: [SourceType.Window])` → `getDisplayMedia({deviceId: {exact: id}})` |
| Encode | libwebrtc's built-in encoder (software VP8 today) |
| Transport | WebRTC. **LAN = ICE host candidates only, zero infrastructure.** Remote = STUN, falling back to managed TURN *(superseded — see status note)* |
| Input | `RTCDataChannel` → `SendInput` (Win) / `CGEvent` (macOS), reached by `dart:ffi`. **Windows needs no native plugin at all** — see §4 |
| Signalling | SDP + ICE candidates over the existing sealed relay channel *(superseded — see status note)* |
| Window picker | Local UI in the desktop app; the phone may *request* a picker but never enumerates |

### Why the app process and not the bridge

This is the load-bearing decision. **macOS TCC.** ScreenCaptureKit is purely TCC-gated — there is no entitlement that grants it, and a raw binary with no bundle identity has nothing for TCC to attach a grant to, so it is denied outright. The bridge ships as a raw Mach-O at `antgrid.app/Contents/MacOS/` (`build-desktop.yml:277`) and can also run as a bare CLI from a terminal, where TCC would attribute the request to Terminal.app. The Flutter app, by contrast, has a stable bundle ID, is Developer ID signed and notarized, and already runs with App Sandbox off (`app/macos/Runner/Release.entitlements`).

Secondary wins: no `bun:ffi`, so the Bun `--compile` embedded-`dlopen` regression is irrelevant; no Rust sidecar to package, sign and notarize; no second artifact in the build matrix; and the consent/picker UI lives where UI already exists.

Cost: screen preview requires the desktop app to be running. This is coherent — capturing a desktop window requires a desktop session, and a headless bridge has no windows to capture.

Frame path: **app captures + encodes → WebRTC direct to the viewer** (relay only carries signalling).

---

## 2. Options evaluated and rejected

| Option | Why rejected |
|---|---|
| **Bun bridge + Rust cdylib via `bun:ffi`** | macOS TCC (above). Also Bun `dlopen` of embedded FFI libs broke in 1.3.14-canary.1 (oven-sh/bun#30717, fixed in #30720) — we run 1.3.14 and pin `1.3.14-alpine` for relay |
| **WebRTC inside Bun** (`node-datachannel` / `libdatachannel` via FFI) | **No congestion control or bandwidth estimation for media tracks at all** — `rtcGetBufferedAmount` always returns 0; REMB is receive-side reporting only with no internal estimator. Delivers none of the benefit that motivates WebRTC |
| **`str0m` / `webrtc-rs`** | Do have real BWE, but sans-IO Rust — only worth it if we were writing the capture engine in Rust anyway, which we are not |
| **Custom native capture plugin** (WGC + ScreenCaptureKit by hand) | Was the fallback plan; unnecessary on Windows now that the spike passed. Still the fallback if macOS fails |
| **RustDesk** | AGPL-3.0 network copyleft — disqualifying for a commercial product |
| **Sunshine / Moonlight** | GPL-3.0 — same problem |
| **Windows RemoteApp / RDP** | Spawns a *separate session*: the user would see a fresh instance, not the app running on their own desktop. Windows Pro only, needs RDP Wrapper for concurrency, no macOS equivalent |
| **VNC** | Full desktop only, no per-window scoping, poor interactivity |
| **scrcpy** | Android only — ruled out once "native app" was confirmed to mean desktop Windows/macOS |
| **Browser `getDisplayMedia` in a WebView** | Same idea as flutter_webrtc but less control; WKWebView support uncertain |

---

## 3. Windows spike — verified results

Run 2026-08-01. Windows 11 Pro 25H2, Flutter 3.44.8, `flutter_webrtc` 1.5.2, libwebrtc **m144.7559.09**, VS Build Tools 2026 (Windows SDK 10.0.26100). Spike lives at `C:\Users\Admin\Documents\wgc_spike` (outside the repo; disposable and reproducible from this doc).

### WGC confirmed at runtime — the make-or-break question

The risk was that libwebrtc would fall back to `BitBlt`/`PrintWindow`, which black-screens GPU-composited windows (Electron, games, Flutter).

- **Static:** `libwebrtc.dll` (20 MB) contains `Windows.Graphics.Capture` (UTF-16 ×4), `WgcCapturer` ×5, `WgcCaptureSession` ×4; imports `d3d11.dll` / `dxgi.dll`.
- **Runtime (decisive):** captured a VS Code window while a maximised Claude window (-8,-8 → 1928,1040) **fully covered** it (232,90 → 1688,998). Output was byte-identical to the unoccluded run — PNG 5,235,657 bytes, meanLuma 28.4, 1448×903, `limitedBy=none`. BitBlt would have shown the occluding window or black.

Occlusion-immunity matters in practice: the developer can keep Antgrid in front while their app streams behind it.

### Measurements (VS Code / Electron window, tuned)

| Metric | Value |
|---|---|
| Resolution | **1448×903**, `limitedBy=none` |
| Framerate | 15–16 fps |
| Bitrate | **~0.8 Mbps** (mostly-static editor) |
| CPU | **29.2% of one core** (2.4% of 12 cores) |
| Memory | 296 MB working set |
| Encoder | `libvpx` — **software VP8** |

CPU is a conservative upper bound: it includes encode *and* loopback decode *and* render; a real sender does not decode.

### Critical tuning finding

**Defaults produce 362×225 — unreadable for testing a UI.** WebRTC treats a screen share as camera video and downscales hard to protect smoothness (`limitedBy=bandwidth`). Setting these took it to 1448×903, trading fps 20 → 15:

```dart
params.degradationPreference = RTCDegradationPreference.MAINTAIN_RESOLUTION;
encoding.maxBitrate = 8000000;
encoding.minBitrate = 1000000;
```

Related gap: **`contentHint` is not exposed in the flutter_webrtc Dart API** (it exists only inside the DLL), so the usual `track.contentHint = 'text'` optimisation is unreachable. `degradationPreference` + an explicit bitrate floor is the only lever.

### Limitations found

- **Minimised windows cannot be captured.** They disappear from enumeration entirely; minimising *mid-capture* collapses the stream to a 1×1 black frame (`captureFrame` → 73 bytes, `fps=null`, framesSent frozen at 100 vs 238 healthy). The app under test must stay visible.
- **Thumbnails are asynchronous.** `getSources()` returns `thumbnail` as 0 bytes; they arrive later via `OnMediaSourceThumbnailChanged`. The picker must subscribe, not read synchronously.
- **Software encode only** on desktop libwebrtc — no hardware path.

---

## 4. Input injection — Windows spike, verified results

Run 2026-08-01, same machine and toolchain as §3. Spike entrypoint `lib/input_spike.dart` + `lib/win32_input.dart` (hand-rolled `dart:ffi`, not `package:win32` — the `INPUT` union layout moved between its major versions). Self-driving: it launches its own targets, gates every injection on the target actually being foreground, and restores the desktop afterwards. Results below reproduced across three consecutive runs.

Targets were chosen to span the frameworks that behave differently: **Flutter** (`FLUTTER_RUNNER_WIN32_WINDOW` → `FLUTTERVIEW` child), **Paint** (WinUI 3, `Microsoft.UI.Content.DesktopChildSiteBridge`), **Notepad** (`RichEditD2DPT`), **Character Map** (classic `#32770` → `CharGridWClass`).

### The capture source id IS the HWND

`DesktopCapturerSource.id` parses directly to a live window handle whose `GetWindowTextW` matches `source.name` — 100% of sources, every run. So the window the user picked for capture is the window we inject into, with no correlation layer, and the owning process is one `GetWindowThreadProcessId` away.

### Injection: two mechanisms, neither sufficient alone

| Target | `PostMessage`, no focus | `SendInput`, with focus |
|---|---|---|
| Flutter | **worked** — click landed exactly on the posted coordinate | worked |
| Notepad (RichEdit) | **worked** — text inserted | worked |
| Paint (WinUI 3) | no effect | worked |
| Character Map | no effect | worked |

`SendInput` worked on **all four**, with 100% of events accepted and no UIPI refusals (nothing under test was elevated). `PostMessage` is framework-dependent and cannot be the primary path — and even where it worked it delivered only the button-down; the ten following `WM_MOUSEMOVE` events never registered as a drag.

Posting must target the deepest child HWND (`ChildWindowFromPointEx` recursively, not `WindowFromPoint` — the target is typically occluded when unfocused). The top-level window never sees mouse input in any of these frameworks.

### Foreground rights are the real constraint

Every `SetForegroundWindow` call succeeded in 1–8 ms — but only because the spike itself held foreground when it asked, which is exactly the condition under which Windows grants the right. Parking a third-party window in front first inverts the result:

- bare `SetForegroundWindow` from a background process → **fails immediately** (returns false, 0 ms)
- `AttachThreadInput` to the foreground thread, then raise → **succeeds, ~5 ms**

So the production path depends on the `AttachThreadInput` workaround, which Microsoft does not sanction and has narrowed before. This is now the largest Windows-side risk in the feature, and it is a *behavioural* dependency, not an API one.

Focus restore measured a consistent **~155 ms** round trip.

**Design consequence:** do not raise-and-restore per input event — that thrashes the local user's focus on every remote tap. Raise once when a remote control session starts and hold the target foreground for its duration, so focus moves once. When the user is genuinely away (the actual remote-control case) focus stealing costs nothing; the cost only appears when someone is sitting at the machine, which is the case that should be surfaced in the UI.

### Coordinate mapping must be measured, not derived

The captured frame matches **neither** `GetWindowRect` nor the DWM extended frame bounds:

| Window | `GetWindowRect` | DWM bounds | Capture frame |
|---|---|---|---|
| Flutter | 1280×720 | 1266×713 | 1272×715 |
| Paint | 1936×1048 | 1920×1032 | 1928×1043 |
| Notepad | 1440×739 | 1430×734 | 1432×734 |
| Character Map | 491×437 | 477×430 | **491×437** (matches `GetWindowRect`) |

The frame is `GetWindowRect` minus (8,5) for every resizable window — including VS Code from §3 — but equals `GetWindowRect` exactly for Character Map, a non-resizable dialog.

Solving the transform empirically (click two known screen points, locate the marks in the frame) gives:

```
screenX = 15.0 + frameX * 1.0000
screenY = 12.0 + frameY * 1.0000     // window at GetWindowRect (10,10), DWM (17,10)
```

**Scale is exactly 1.0** — no resampling at 100% display scaling, so a frame pixel is a screen pixel. The origin is a small per-window offset that is neither rect's origin (+5,+2 from `GetWindowRect`; −2,+2 from DWM bounds). Before shipping, pin this down from libwebrtc's cropping logic rather than by calibration — a product cannot click twice in the user's app to find out where its own pixels are. Untested at display scaling ≠ 100%, which is where a non-unit scale would appear.

### Input transport is not a concern

`RTCDataChannel` loopback round trip for an input-event-sized JSON message: **median 1.4–2.4 ms, p95 2.4–4.3 ms** across runs (n=50 each). Negligible beside network RTT and the ~155 ms focus round trip — the transport was never the risk.

### Method note

Verdicts are pixel diffs of captured frames, since a GPU-composited app exposes no child HWND to interrogate. Two corrections were needed before the numbers meant anything, both worth remembering for any repeat:

- **Baseline must be captured in the same focus state as the measurement.** Activating or deactivating a window repaints its title bar, which reads as a successful injection. Every measurement now sets focus first, then baselines, and records a no-input noise floor for comparison (measured 0 px in almost every case).
- **Count pixels, not percentages.** Seven characters of text in a 1400px-wide window is ~0.1% of pixels; a percentage threshold cannot separate that from nothing. Absolute changed-pixel counts plus a bounding box work — a real injection is spatially clustered, and the Flutter probe's bbox came back as exactly 80×80, the diameter of the circle it was supposed to draw.

## 5. Cost model

Measured ~0.8 Mbps ≈ **360 MB/session-hour**.

Relaying video through our own infra is the most expensive option: prod is a single `Standard_D2as_v7` in `westus` running relay + web, and Azure egress is **$0.087/GB** Zone 1 / **$0.12/GB** Zone 2 (staging is `southeastasia`) after 100 GB/month free → roughly **$0.03–0.04 per session-hour**, plus a scaling cliff on a 2-vCPU box.

`infra/tofu/network.tf` opens **only TCP 22/80/443** — no UDP — so **we cannot self-host coturn on current infra** without new NSG rules and TURN traffic competing with the control plane.

This is why the transport order matters:

1. **LAN direct** — ICE host candidates connect on the same subnet with no STUN and no TURN. Zero infrastructure, zero egress. Covers the dominant case (developer at a desk, phone on the same Wi-Fi).
2. **Remote** — STUN (free) + managed TURN. Cloudflare Realtime TURN is $0.05/GB with 1,000 GB/month free, and only bills the ~15–30% of sessions that fail P2P. *(superseded — see status note)*

---

## 6. Security decisions (settled)

Screen capture plus input injection is categorically larger than "tail a terminal", and is treated as a new capability:

- ~~**The local user picks the window**, in local UI. A remote peer may request a picker but must never enumerate or select windows unprompted — that would be a screen-scraping primitive over the network.~~ **Superseded 2026-08-04:** either end may pick, chosen by the request's `chooser`. Viewer-side picking is gated on the screen-control switch, publishes titles only (never thumbnails), and accepts a pick only against the catalog the host last published.
- **No full-desktop mode, ever.** Not as a config flag.
- **Its own policy switch**, separate from the machine-level remote-access boolean (`bridge/src/remote-access-policy.ts`), so remote terminal control does not imply remote screen control.
- **Do not request borderless capture.** WGC draws a yellow border by default; removing it needs `GraphicsCaptureAccessKind.Borderless` and is Windows 11 only. The OS-enforced indicator is exactly the persistent capture indicator we wanted — take it for free. macOS gives the equivalent menu-bar indicator. There is a second, stronger reason: suppressing the OS capture indicator is the clearest single signal separating legitimate screen sharing from spyware, to Store reviewers and AV heuristics alike (see *Microsoft Store distribution* below).
- Session scoped to one window handle, auto-expiring, killed when the window closes. Frames ephemeral — never to disk, never into scrollback.

### Microsoft Store distribution and AV risk

Grounded in what we already ship: MSIX via Partner Center (`msix_config` in `app/pubspec.yaml`), Store-assigned identity `CN=D6BFB7D7-…`, so **Microsoft signs the package** — SmartScreen reputation is a non-issue on the Store channel. (The direct-download channel in `build-desktop.yml` is unsigned by default; that is a separate problem, unrelated to this feature.) Flutter's MSIX is full-trust `Windows.FullTrustApplication`, so `SendInput`/`AttachThreadInput` are available and `capabilities: internetClient` remains sufficient — this feature declares nothing extra.

**The injection path is a poor match for AV heuristics.** Defender PUA/RAT detection keys on code injection and stealth: `WriteProcessMemory`, `CreateRemoteThread`, global `SetWindowsHookEx`, obfuscated loaders, hidden windows, persistence. `AttachThreadInput` + `SendInput` write no memory into the target and install no hooks. Keep it that way — a global keyboard hook or an injected DLL would deliver the same functionality with a far worse signature.

**Precedent:** the product already ships remote terminal control and PTY execution driven from a phone, which is a higher-capability remote-access surface than screen capture, and it has passed certification. This is an increment within an established category, not a new one.

**Exposure is behavioural, not API-level.** This is the second and stronger reason for the decisions above: keeping the WGC yellow border, refusing full-desktop capture, and requiring the local user to choose the window are exactly what separate this from stalkerware in both Store review and AV heuristics. Never add a headless/invisible capture mode, capture-on-boot, or indicator suppression — any one of them inverts the risk profile.

**`uiAccess` is permanently unavailable.** Setting `uiAccess=true` requires a trusted certificate *and* installation under Program Files; a Store MSIX can satisfy neither. Injection into elevated windows is therefore impossible by construction rather than merely untested. Design for detection and a clear error, never a workaround.

**Not verified:** the certification outcome itself. Store policy text changes — re-check the current policies on privacy/personal information and on app behaviour before submitting, expect a possible manual review question specifically about injecting input into third-party apps, and make sure the privacy policy URL covers screen capture explicitly.

### macOS distribution — no review gate, a permanent runtime one instead

We ship Developer ID + notarized DMG (Sparkle for updates), App Sandbox intentionally **off** (`app/macos/Runner/Release.entitlements`), Hardened Runtime on via `--options runtime`. That shape decides most of this.

**There is no `uiAccess` analogue and, more importantly, no reviewer.** Notarization is an automated malware scan — signing, hardened runtime, known-malware matching. It does not evaluate what the app *does*. The entire Store risk class above (review objections, policy interpretation, questions about third-party injection) does not exist on this channel. This is the opposite of the usual intuition that Apple is the stricter of the two.

**No new entitlements are needed.** Screen capture and `CGEventPost` are TCC-gated, not entitlement-gated, and the sandbox is off — `Release.entitlements` stays empty. Stated explicitly because the natural assumption is that this feature must add something there.

**macOS is harder at runtime instead, and TCC is the whole story:**

- **Two separate grants** — Screen Recording *and* Accessibility. Both are user toggles in System Settings; an app can only prompt or deep-link to the pane, never grant them itself.
- **Neither has a customisable usage-description string**, unlike camera or microphone. The justification cannot appear in the system dialog, so it has to live in our own pre-prompt UI. That is a design constraint, not a detail.
- **Screen Recording generally requires an app restart** to take effect; Accessibility usually does not.
- **Grants bind to the code signature and bundle ID.** They survive Sparkle updates while the Developer ID and bundle ID are stable, but rotating the Team ID silently re-prompts every existing user.
- **macOS 15 introduced periodic re-authorisation reminders for screen capture.** Apple adjusted the cadence during the 15.x cycle; verify against the OS version actually targeted.

**The UIPI analogues are narrower but real:** *Secure Event Input* drops synthetic keystrokes whenever an app enables it (password fields, Terminal's Secure Keyboard Entry, the login window) — the same "my typing does nothing" symptom. Apple also blocks synthetic clicks on its own security prompts including TCC dialogs, so the consent flow can never be automated. Protected/DRM content captures as black frames; the login window and lock screen are off-limits entirely.

**Where macOS may be *worse* than Windows:** the activation question in §7 item 2. `NSRunningApplication.activate` has been restricted since Ventura, with a cooperative `activate(from:)` added later. Windows had a working if unsanctioned escape in `AttachThreadInput`; macOS has no equivalent, because Apple closed those paths deliberately. If a backgrounded app cannot raise another app's window there may be **no workaround at all**, only a design change — making this a higher risk here than the same question was on Windows.

---

## 7. Open questions / next steps

Ordered by risk.

1. **macOS window capture — settled 2026-08-10, and the answer is no.** **[verified]**
   Measured on macOS 26.4.1 / arm64 / Xcode 26.6, against the pod this branch
   resolves (`WebRTC-SDK 144.7559.09`), by probing the shipped framework binary
   rather than reading vendor docs.

   Both layers route windows away from SCK. The plugin selects SCK only for
   `sourceType == RTCDesktopSourceTypeScreen`, so every window source falls to
   `RTCDesktopCapturer` — and the `macos/Classes/` and `common/darwin/Classes/`
   copies of `FlutterRTCDesktopCapturer.m` are byte-identical while the podspec
   compiles `Classes/**/*`, so that is what ships. libwebrtc does not rescue it
   underneath: the framework carries the log string `CreateRawWindowCapturer
   creates DesktopCapturer of type WindowCapturerMac`, and `CreateGenericCapturerSck`
   / `WindowCapturerSck` are **absent from the binary entirely**. SCK *is*
   compiled in (`ScreenCapturerSck`, `SckPickerHandle`, weak-linked
   `ScreenCaptureKit`) but wired to displays and the system picker only — and the
   system picker is Apple's own UI, which collides with viewer-side picking.

   So window capture terminates in `CGWindowListCreateImage`, which the 26.4 SDK
   marks `obsoleted=15.0`.

   **The API is still alive at runtime.** Capturing our *own* window — which TCC
   does not gate — returned real pixels, so `obsoleted` is a compile-time
   attribute and nothing more. That is precisely what does *not* rescue the
   design: new code cannot compile against it, we are two majors past
   deprecation, and upstream offers no window path to migrate onto.

   **Consequence: macOS needs an SCK window-capture path regardless**, so this
   is no longer a question to answer but work to schedule. It is smaller than
   this doc assumed when it called for a whole native plugin —
   `FlutterScreenCaptureKitCapturer.m` is ~150 lines and already pumps
   `RTCVideoCapturer` through a delegate. It needs
   `SCContentFilter initWithDesktopIndependentWindow:` beside the existing
   `initWithDisplay:excludingWindows:`, sizing from the window frame, and window
   sources routed to it. That is an upstream PR, not a fork.

   Method note for any repeat: TCC denial and a dead API are indistinguishable
   from the outside — both return NULL. Capturing a window the probe owns is
   what separates them, and it needs no grant.
2. **macOS input injection — API surface settled 2026-08-10; delivery still unmeasured.**
   Read out of the 26.4 SDK, this is *less* dangerous than §6 feared. The whole
   `CGEvent` family carries **no deprecation** — unlike capture, the injection
   APIs are current. More importantly `CGEventPostToPid` (10.11+) exists and is
   documented for exactly this shape: "an application to establish an event
   routing policy … posting the events to another desired process." Windows'
   nearest analogue was `PostMessage`, which §4 measured as framework-dependent
   and failing outright on WinUI 3 and Character Map. **If per-pid delivery
   works, the backgrounded-activation problem largely dissolves**, because
   nothing needs raising — so measure `CGEventPostToPid` before anything else.

   `NSRunningApplication activateWithOptions:` is also **not** deprecated in
   26.4; `activateFromApplication:options:` (14.0+) is the cooperative addition.
   Their return contracts differ in a way the design should exploit:
   `activateWithOptions:` reports only that the request was *sent*, whereas
   `activateFromApplication:` reports whether the system *allowed* it — only the
   latter can detect refusal.

   What remains blocked on an Accessibility grant: whether posted events land at
   all, and whether a backgrounded target processes them. A probe on a
   grant-less machine received **0 events** from both `CGEventPostToPid(self)`
   and `CGEventPost(kCGSessionEventTap)`, with Secure Event Input off — that is
   consistent with the grant being mandatory, but a local `NSEvent` monitor
   cannot separate it from the probe window not being key, so treat it as
   suggestive rather than measured.
3. **`AttachThreadInput` durability (Windows).** §4 showed the production path depends on it whenever the app is backgrounded. It is an unsanctioned workaround Microsoft has narrowed before. Worth deciding whether to depend on it, or to require that the Antgrid window be foreground when a control session starts (which the raise-once design makes reasonable).
4. **Exact frame origin.** §4 established scale is exactly 1.0 and the offset is a small per-window constant matching neither rect. Read it out of libwebrtc's cropping logic rather than calibrating at runtime, and re-measure at display scaling ≠ 100%, where a non-unit scale would show up.
5. **Elevated windows are out of scope permanently, not pending.** `UIPI` silently drops injection into them, and a Store MSIX can never set `uiAccess` to escape it (see §6). So this is no longer a spike — the remaining work is detecting the case and showing a clear error, since "my clicks do nothing" against an admin app is otherwise unexplainable to a user.
6. **Real-network measurement** — LAN and cellular, rather than loopback.
7. **Binary size — measured 2026-08-10.** **[verified]** `WebRTC.xcframework` is
   141 MB unpacked, but that spans every Apple platform; the macOS slice is
   **27 MB fat** — arm64 12 MB, x86_64 15 MB — so an arm64-only DMG pays 12 MB.
   Windows remains the 20 MB `libwebrtc.dll` of §3.
8. **Privacy/crypto deltas of P2P** — ICE exposes peer IPs (today the bridge never reveals its address to the app), and DTLS-SRTP is a second crypto path beside X25519+AES-GCM. Bind the DTLS fingerprint inside the sealed signalling to close signalling MITM. Note the relay then sees *nothing* of the media, which is better for zero-knowledge but worse for metadata.
9. **macOS signed dev builds — settled 2026-08-10; the bar is lower than assumed.**
   **[verified]** What matters is TCC *registration*, and a distribution identity
   is not required for it. An **ad-hoc** signature (`codesign -s -`) creates no
   TCC row at all — `tccutil` answers `No such bundle identifier`, so it cannot
   even be granted by hand, and launching the bundle standalone at `ppid=1` does
   not change that. Signing the same bundle with an ordinary **Apple Development**
   certificate registers it immediately (`kTCCServiceScreenCapture|<bundle id>|0`)
   and it becomes togglable in System Settings. So local macOS capture work needs
   a developer cert, nothing more.

   Two traps worth carrying into any repeat. TCC attributes a request to the
   **responsible process**, so a probe launched from an IDE's integrated terminal
   inherits that IDE's verdict rather than earning its own — if the IDE is
   already denied, the request fails instantly with no prompt and no row, which
   reads exactly like a broken API. And on an MDM-managed Mac an administrator
   can push a PPPC profile granting Screen Recording and Accessibility by bundle
   ID; on a rented or corporate machine that is usually an easier ask than local
   admin rights.

### Effort

~**2–3 weeks** for Windows + macOS v1, assuming macOS capture passes: signalling glue 2–3 days, consent/policy/lifecycle 3–4 days, picker wired to the Antgrid design system 2–3 days, macOS input injection ~4 days. Windows input injection is now ~2 days rather than a week — §4 proved out the whole path (`dart:ffi` direct to `user32`, no native plugin, no C++ in the build) and the spike code is close to liftable. If macOS capture fails, add a native ScreenCaptureKit plugin for macOS window capture only.

---

## 8. Build gotchas (Windows)

- **Developer Mode must be on** — Flutter needs symlink support for plugins.
- **MSBuild's C++ toolchain cannot build under `%TEMP%`.** It emits `MSB8029` then `MSB6003: link.exe could not be run … CompilerIdCXX.tlog` not found, which surfaces misleadingly as **"No CMAKE_CXX_COMPILER could be found."** Keep Flutter Windows build directories outside temp paths — relevant if CI ever builds in a temp workspace.
