# Screen stream quality — findings and available levers

**Date:** 2026-08-06
**Status:** Research complete, no code changed. Claims marked **[verified]** were read out of the toolchain installed on this machine (plugin sources, prebuilt `libwebrtc.dll`), not from vendor documentation. Claims marked **[inferred]** are reasoned from measurement and need one experiment to confirm.
**Goal:** raise perceived quality and connection stability of the native app preview stream, and settle whether a different remote-desktop stack would do it better.
**Builds on:** [2026-08-01-native-app-preview.md](2026-08-01-native-app-preview.md) — §2 (options rejected) and §3 (capture measurements) are the baseline this does not restate.
**Touches:** `app/lib/services/webrtc_screen_backend.dart`, `webrtc_screen_view_backend.dart`, `screen_ice_config.dart`, `app/pubspec.yaml`

> **Status in this repo (2026-09-30).** Written against an older internal codebase and kept as history. Where the body disagrees with this note, the note wins; passages it overturns are marked *(superseded — see status note)*.
>
> - **Signalling rides Iroh project streams, peer-addressed.** `bridge/src/screen-relay.ts` stamps `viewerId` on every viewer→host `screen:*` frame from the viewer's lease-authenticated peer id and delivers it to the loopback owner only. The host must put `viewerId` on every frame it sends; the bridge drops unaddressed ones and delivers addressed ones to that one peer. No broadcast and no echo back to the sender, so neither side does echo suppression. The bridge pushes the lifecycle ends itself: `screen:stop{reason: "viewer-gone"}` to the host when a viewer's session closes, `screen:state{status: "no-host"}` to viewers when the host disconnects, and on screen-control or remote-access revocation `screen:stop` to the host plus `screen:state{status: "ended"}` to the viewer.
> - **The TURN seam was removed.** TURN was never provisioned; ICE is STUN plus host candidates only (`app/lib/services/screen_ice_config.dart`). Off-LAN sessions that hole punching cannot connect are the target of a planned spike tunnelling ICE-TCP through an Iroh stream.
> - **iroh-live (n0's Media-over-QUIC) was evaluated and deferred.** Revisit when it runs on Windows, supports single-window capture, and has a tagged release. Media sits behind `ScreenShareBackend` / `ScreenViewBackend` (`app/lib/services/`), so it can drop in without touching the services or UI.

---

## 1. MeshAgent KVM — evaluated, rejected

Raised as a candidate on the theory that it resembles RDP. It does not; see §2.

MeshCentral's agent is Apache-2.0, which clears the bar RustDesk (AGPL) and Sunshine (GPL) failed in findings §2. That is its only advantage over what is already built. Four disqualifiers, read from source:

| Finding | Evidence |
|---|---|
| Captures displays, never windows | Windows `kvm.c` enumerates via `EnumDisplayMonitors()`, targets a display through `SCREEN_SEL`; macOS `mac_kvm.c` calls `CGDisplayCreateImage(screen_num)`. No HWND path exists. |
| Windows capture is GDI | Active path is GDI/GDI+ tile capture; the DXGI Desktop Duplication code in the file is commented out. GDI black-screens GPU-composited windows — Electron, Flutter, games — the exact failure mode the WGC spike was built to rule out (findings §3). |
| macOS is the same deprecated generation | `CGDisplayCreateImage` is deprecated alongside `CGWindowListCreateImage`. Adopting it does not retire the macOS risk in findings §7 item 1; it keeps the risk and loses per-window scoping. |
| No rate control | CRC-diffed JPEG tiles over MeshCentral's binary protocol. Its WebRTC stack is **data-channel only, no media**. That re-introduces the "no congestion control or bandwidth estimation" property that disqualified `node-datachannel` in findings §2. |

Full-desktop-only also collides head-on with the settled decision in findings §6 ("No full-desktop mode, ever. Not as a config flag").

Secondary costs, either of which would be enough on its own: a large C codebase shipping as a per-platform sidecar binary — the packaging/signing/notarisation cost findings §1 rejected — and a Store/AV posture inversion. MeshAgent is among the most-abused RMM agents in the wild with published vendor detection content; the findings §6 certification argument rests on our injection path being a *poor* heuristic match and on keeping the WGC yellow border. Embedding a known-abused agent doing indicator-free full-desktop capture inverts both halves.

**Worth keeping as reference, not as a dependency:** `mac_kvm.c`'s `kvm_check_permission()` is a working example of the two TCC grants findings §6 flags as having no customisable usage string — `CGRequestScreenCaptureAccess()` and `AXIsProcessTrustedWithOptions()` plus the deep-link-to-Settings flow. Its newer `-kvmagent` mode connects to a user-space LaunchAgent over a per-uid Unix socket (`/tmp/meshagent-kvm-<uid>.sock`) specifically to dodge audit-session isolation on recent macOS. Both are directly relevant to Phase 7.

## 2. RDP is not the comparison it appears to be

RDP earns its quality reputation through RemoteFX/AVC 444, bitmap and glyph caching, dirty-rect ordering, and a bandwidth autodetect loop. MeshAgent KVM shares none of that machinery — it is a screenshot differ with a good transport around it, well matched to poking at a mostly-static helpdesk desktop and badly matched to a UI that animates, where every tile is dirty every frame with no bitrate ceiling and nothing to back off with.

RDP proper remains unavailable for the reason in findings §2: it spawns a separate session, so the user sees a fresh instance rather than the app they are debugging. Session shadowing (`mstsc /shadow`) does attach to the live console session, but it is Windows-Pro-only, full-desktop, frequently policy-blocked, and needs a Windows client — the viewer here is a phone.

## 3. What the shipped libwebrtc actually contains **[verified]**

Probe of `flutter_webrtc-1.5.2/third_party/libwebrtc/lib/libwebrtc.dll` (20 MB, ASCII string occurrence counts):

| Symbol | Count | Reading |
|---|---|---|
| `LibvpxVp9Encoder` | 15 | VP9 encode available |
| `LibaomAv1Encoder` | 10 | AV1 encode available |
| `H264EncoderImpl` / `OpenH264` | 2 / 11 | H.264 encode via openh264 — software, Constrained Baseline |
| `WgcCapturer` | 5 | Windows Graphics Capture present (matches findings §3) |
| `MediaFoundation`, `NVENC` | 0 / 0 | **no hardware encode path at all** |
| `screen_content` | 1 | screen-content coding compiled in, but nothing turns it on — see §4 |
| `flexfec`, `ulpfec`, `transport-cc` | 7 / 7 / 2 | FEC and congestion-control feedback present |

`profile-level-id` hex strings (`42e01f` etc.) return zero because WebRTC formats them at runtime — absence there is not evidence of a missing profile. `Windows.Graphics.Capture` returns zero in ASCII because it is stored UTF-16, consistent with findings §3.

**Consequence:** all three codecs are reachable via `setCodecPreferences`, which is exposed in `webrtc_interface-1.5.1` (`rtc_rtp_transceiver.dart:34`) and implemented natively at `common/cpp/src/flutter_webrtc.cc:1169`. Nothing in `app/lib/` calls it today, so VP8 is being negotiated by default. Encode is software-only and will stay that way short of building libwebrtc ourselves.

## 4. The encoder is running in camera mode — and it is a Windows-only gap **[verified + inferred]**

`videoSourceForScreenCast:YES` appears exactly once in the entire plugin: `common/darwin/Classes/FlutterRTCDesktopCapturer.m:28`. The Windows C++ path has no equivalent call. **[verified]**

That predicts findings §3's most confusing measurement. Defaults collapsing to 362×225 with `limitedBy=bandwidth` is camera-source behaviour: a screencast-flagged source degrades framerate rather than resolution, which is precisely why `MAINTAIN_RESOLUTION` had to be forced by hand at `webrtc_screen_backend.dart:242`. **[inferred]**

Two consequences worth stating plainly:

- macOS will likely behave better here for free, since the darwin path already sets the flag. This is a Windows defect, not a cross-platform one.
- Enabling it lifts VP8/VP9/AV1 and does nothing for H.264, which has no screen-content mode — see §6.

**Cheap experiment before any patch.** Windows passes `ParseMediaConstraints(video_constraints)` into `CreateDesktopSource` (`common/cpp/src/flutter_screen_capture.cc:324`), and `third_party/libwebrtc/include/rtc_mediaconstraints.h:57` exposes `kScreencastMinBitrate` (`googScreencastMinBitrate`). That is a generic key-value forward, so it can be tried from Dart with no plugin fork. If `qualityLimitationReason` does not move, the fix is a small patch mirroring the darwin call — a good upstream PR rather than a permanent fork.

## 5. `mediaSource: 'screen'` is a no-op, and the usual snippet is dangerous here **[verified]**

The string `mediaSource` appears nowhere in flutter_webrtc 1.5.2 — not in Dart, not in `common/cpp`, not in the Windows path. `GetDisplayMedia` (`common/cpp/src/flutter_screen_capture.cc:186`) reads exactly three inputs: `video.deviceId.exact`, `video.mandatory.frameRate`, and `audio`. Everything else in the constraints map is silently dropped.

**The trap:** the widely-circulated `{'video': {'mediaSource': 'screen'}}` snippet omits `deviceId`, and the C++ then defaults `source_id` to `"0"` — the first display. The result is not a screencast hint; it is **silent full-screen capture**, the one mode findings §6 rules out permanently. `'deviceId': {'exact': windowId}` is non-negotiable in that map.

On the premise: `mediaSource` is a legacy Firefox `getUserMedia` constraint, superseded by `getDisplayMedia` itself — a *capture selection* API. `is_screencast` is a different layer, an internal libwebrtc video-source property that selects the encoder's screenshare mode. Calling `getDisplayMedia` does not set it.

## 6. Codec choice

**VP9 is the target; H.264 is a fallback tier, not a default.**

H.264 here means openh264 (no MediaFoundation in the build, §3), which is Constrained Baseline: 4:2:0 chroma, CAVLC, no 8×8 transform, no screen-content tooling. 4:2:0 carries colour at a quarter resolution, which is the pathological case for syntax-highlighted code — thin coloured glyphs on a dark background bleed and smear toward each other. Microsoft built AVC 444 for RDP precisely to work around this; we have no equivalent lever.

Where H.264 genuinely wins, and why it stays on the table:

- **Viewer decode.** Hardware H.264 decode exists on every phone. Lower latency, materially less battery and heat over a long session. VP9 hardware decode is common on Android but should be **verified on the iOS targets rather than assumed**; AV1 hardware decode is confined to recent silicon (roughly Apple A18/M3-era, Snapdragon 8 Gen 2+), so AV1 on most phones today means software decode.
- **Host encode cost.** Everything is software encode, so CPU is a live constraint at the ~29%-of-a-core measured in findings §3. openh264 CBP is cheapest; AV1 is the most expensive by a wide margin.

`setCodecPreferences` is per-transceiver, so this is a per-session decision rather than a build-time one: negotiate H.264 when the viewer reports no VP9 hardware decode, or when host CPU is contended.

AV1 warrants exactly one measurement run — best screen-content tools of the three — but encode CPU plus software decode on the phone likely rules it out for now.

## 7. flutter_webrtc 1.6.0 — take it, but not for this

Installed: **1.5.2**. Latest: **1.6.0** (changelog dated 2026-07-29). The 1.6.0 changelog contains nothing touching this work — no `contentHint`, no screencast, no desktop capturer, no Windows changes, and the same libwebrtc `m144.7559.09` already measured against. Upgrading will not fix §4 or unlock `contentHint`.

Take it as hygiene, in a **separate commit from screen work** so a regression bisects cleanly. One entry matters independently: 1.6.0 replaces the private `RPSystemBroadcastPickerView` with public UIKit APIs for App Store compliance. We do not ship iOS screen capture, but private-API usage in a linked framework is flagged at submission regardless of whether we call it.

`contentHint` remains unreachable — confirmed absent from the plugin's C++ wrapper and the `libwebrtc` headers, not merely from the Dart API. `degradationPreference` plus an explicit bitrate floor is still the whole of it.

## 8. Remaining levers, ranked

Agreed direction: upgrade to 1.6.0, set the screencast flag, switch to VP9, reduce framerate. Two interactions to respect:

- Screenshare mode adapts framerate on its own — **do not over-cut capture fps before re-measuring** with the flag on.
- When fps drops, the lever protecting text is the **floor** (`minBitrate`), not the 8 Mbps ceiling. The floor is what stops BWE starving a static frame.

### Free wins in the installed API

1. **Viewer `filterQuality`.** `webrtc_screen_view_backend.dart:93` builds `RTCVideoView` without it, taking the plugin default `FilterQuality.low` (`rtc_video_view_impl.dart:15`). Downscaling 1448×903 into a phone viewport at `low` aliases thin glyphs — the shimmering-text artifact. `FilterQuality.medium` enables mipmapped sampling, the correct mode for downscale. One line, no host cost.
2. **`RTCRtpEncoding.maxFramerate`.** Capture-side `frameRate` limits the capturer only; `maxFramerate` caps the encoder independently. Set both — they fail differently.
3. **Temporal layers.** `scalabilityMode` and `numTemporalLayers` are exposed (`rtc_rtp_parameters.dart:62`, `:59`) and VP9 implements SVC properly, unlike VP8. `L1T2`/`L1T3` sheds frames under loss instead of dropping resolution or stalling — pairs naturally with the VP9 switch.
4. **Peer-connection config.** `createPeerConnection` (`webrtc_screen_backend.dart:114`) passes only `iceServers` and `sdpSemantics`. `bundlePolicy: 'max-bundle'` + `rtcpMuxPolicy: 'require'` cut candidate pairs; `iceCandidatePoolSize` pre-gathers so the offer ships with candidates in hand. Connect-time latency, which is what users read as flakiness.

### Stability — a separate axis from quality

5. **ICE restart.** The largest remaining gap. `webrtc_screen_backend.dart:200` and `webrtc_screen_view_backend.dart:84` map connection state to UI, but nothing calls `restartIce()`; a Wi-Fi→cellular handover ends the session rather than recovering it.
6. **Real TURN credentials** through the `IceServerResolver` seam in `screen_ice_config.dart`. Without them, off-LAN is a coin flip on hole punching. *(superseded — see status note)*
7. **Stats-driven telemetry.** `encodedFrameSize()` (`webrtc_screen_backend.dart:314`) already walks `outbound-rtp`; two extra field reads give `qualityLimitationReason`, `framesDropped`, `freezeCount` — both a tuning feedback loop and the material for an honest UI state instead of the user watching it blur and assuming the feature broke.

### Worth knowing exists

8. **Loopback audio is already implemented in the plugin.** `flutter_screen_capture.cc` carries a full Windows loopback capturer with audio processing correctly disabled for system audio; we pass `'audio': false`. Not a video lever, but the platform side is done if previewing an app with sound is ever wanted.
9. **A user-facing quality mode.** Sharp (low fps, high per-frame bits) versus Smooth is a real preference split — a static form layout and an animation want opposite tunings. Cheap once encoding params are parameterised by items 2–3.

**Suggested order:** items 1 and 5 first (small changes, directly visible to the user), then the four agreed changes, then items 2–3 tuned against the numbers item 7 produces.

## 9. Open questions

1. Does `googScreencastMinBitrate` through the constraints map move `qualityLimitationReason`, or is a plugin patch required (§4)?
2. VP9 hardware decode on the iOS targets — assumed absent until measured (§6).
3. The measurement that settles codec choice: same window, same bitrate cap, VP8 vs VP9 vs H.264 — text legibility at 100% zoom, host CPU, viewer battery over ten minutes.
4. Whether hardware encode is ever worth building libwebrtc for. That is the point at which a different stack (GStreamer `webrtcbin` + NVENC/QSV) becomes a fair comparison — not before.
