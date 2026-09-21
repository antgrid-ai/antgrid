# Real-time voice input platform research

Last verified: 2026-09-19

## Summary

Antgrid should expose voice transcription through a backend-neutral interface and
prefer operating-system speech services where they provide a genuine on-device
guarantee. Parakeet through sherpa-onnx is the practical Windows fallback and a
potential fallback for unsupported devices or locales, but it should not be a
mandatory download on platforms with a suitable system recognizer.

Recommended initial routing:

| Platform | Preferred backend | Fallback |
| --- | --- | --- |
| iOS/iPadOS 26+ | Apple SpeechAnalyzer and SpeechTranscriber | Legacy Apple on-device recognition or optional Parakeet |
| Android 12+ | Android on-device SpeechRecognizer, when available | Optional Parakeet |
| macOS 26+ on Apple silicon | Apple SpeechAnalyzer and SpeechTranscriber | None initially; optionally legacy Apple recognition |
| Windows | Parakeet TDT INT8 through sherpa-onnx | Microsoft.Windows.AI.Speech after it becomes stable |

Voice transcripts should be inserted into the prompt composer for review. They
should not be submitted automatically, because transcription errors can turn
into destructive agent commands.

## NVIDIA Parakeet

### Purpose-built streaming model

`nvidia/parakeet_realtime_eou_120m-v1` is designed for streaming voice-agent
pipelines. It emits an end-of-utterance token and NVIDIA reports an 80-160 ms
streaming configuration. Its model card reports end-of-utterance latency of
approximately 160 ms at p50, 280 ms at p90, and 320 ms at p95.

Limitations:

- English only.
- No punctuation or capitalization.
- NVIDIA's documented runtime is NeMo on Linux with CUDA.
- The documented model requires 16 kHz mono audio and at least 160 ms of audio.

Source: [NVIDIA Parakeet Realtime EOU model card](https://huggingface.co/nvidia/parakeet_realtime_eou_120m-v1)

### Cross-platform Parakeet through ONNX

Parakeet itself is not limited to NVIDIA's NeMo deployment path. Quantized ONNX
exports of Parakeet TDT can run through sherpa-onnx on CPU without CUDA, Python,
or WSL.

Orca uses this approach. Its package manifest includes sherpa-onnx native
packages for Windows, macOS, and Linux, and Orca recommends Parakeet TDT v3 for
offline dictation.

Sources:

- [Orca voice settings](https://www.onorca.dev/docs/settings)
- [Orca package manifest](https://github.com/stablyai/orca/blob/main/package.json)
- [sherpa-onnx Flutter Parakeet examples](https://github.com/k2-fsa/sherpa-onnx/blob/master/flutter/sherpa_onnx/example/example.md)

The sherpa-onnx Parakeet TDT v3 package is an offline utterance recognizer, not a
true streaming model. Push-to-talk or VAD records an utterance and decodes it
after the utterance ends. Repeatedly decoding a growing buffer can simulate
partial results, but wastes increasing amounts of computation.

Source: [sherpa-onnx Parakeet streaming discussion](https://github.com/k2-fsa/sherpa-onnx/issues/2918)

Parakeet TDT v3 supports 25 European languages and includes punctuation and
capitalization. V2 is English-only and can be offered as a faster alternative.

## Installation and resource costs

Approximate Windows x64 costs for Parakeet TDT v3 INT8:

| Component | Approximate size |
| --- | ---: |
| sherpa-onnx and ONNX Runtime native libraries | 15-25 MB installed |
| Compressed Parakeet model download | 487 MB decimal / 465 MiB |
| Extracted model files | 670 MB decimal / 639 MiB |
| Steady-state additional disk use | About 690 MB |
| Peak disk use during download and extraction | About 1.2 GB |

The model consists primarily of a roughly 652 MB encoder, plus an approximately
12 MB decoder and 6 MB joiner. The Windows native runtime consists primarily of
ONNX Runtime and the sherpa native library.

Sources:

- [Orca model archive report](https://github.com/stablyai/orca/issues/9231)
- [Parakeet v3 INT8 model files](https://huggingface.co/twmht/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/tree/main)
- [sherpa-onnx native library sizes](https://github.com/k2-fsa/sherpa-onnx/blob/master/java-api-examples/maven-examples/README.md)

The native runtime can be bundled while the model remains an opt-in download.
The product should show roughly "500 MB download, 700 MB disk space," verify a
pinned SHA-256 checksum, extract into a staging directory, atomically move the
validated model into place, and delete the compressed archive. Settings should
provide model status, retry, and removal controls.

Runtime memory is a separate concern. A sherpa-onnx issue reports approximately
1.23 GB of memory while Parakeet v3 INT8 is loaded on iOS. Memory consumption
must be measured on every supported platform and low-memory devices should be
gated or use the native system backend.

Source: [Parakeet INT8 memory report](https://github.com/k2-fsa/sherpa-onnx/issues/2626)

## iOS and iPadOS

### Preferred native backend

On iOS/iPadOS 26+, SpeechAnalyzer with SpeechTranscriber provides:

- Fully on-device transcription.
- Live volatile and finalized results.
- Low-latency transcription with punctuation.
- System-managed, locale-specific model downloads.
- Models shared between applications and kept outside the application's memory
  space.
- Voice activity detection through SpeechDetector.
- Contextual vocabulary and custom language-model support.

Apple states that the speech model does not increase the app's download size,
storage size, or runtime-memory size. AssetInventory downloads and maintains the
necessary models and shares them between apps.

Sources:

- [Apple WWDC25 SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/)
- [SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer)
- [SpeechTranscriber documentation](https://developer.apple.com/documentation/speech/speechtranscriber)
- [AssetInventory documentation](https://developer.apple.com/documentation/speech/assetinventory)

For older OS versions, SFSpeechRecognizer can be used only after checking
`supportsOnDeviceRecognition` and setting `requiresOnDeviceRecognition` to true.
Some locales require a network connection. Antgrid must never silently fall back
to network recognition while presenting the feature as private or offline.

Sources:

- [supportsOnDeviceRecognition](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
- [SFSpeechRecognitionRequest](https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest)

### Downloading a third-party model

iOS permits an application to download ML model data after installation. The
signed sherpa-onnx native runtime must remain in the app bundle; native dynamic
libraries or executable code must not be downloaded.

For broad OS compatibility, a background URLSession can download the model over
HTTPS. Store installed model files in Library/Application Support and mark them
with `isExcludedFromBackup`, because they can be downloaded again. Use a
temporary location for the archive and extraction staging directory.

Sources:

- [Apple background downloads](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple file-system guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
- [App Review Guideline 2.5.2](https://developer.apple.com/app-store/review/guidelines/)

Apple's Background Assets framework explicitly supports machine-learning
models. Apple-hosted managed assets are useful for newer deployment targets,
but ordinary URLSession downloads remain simpler for a broad OS range. Legacy
On-Demand Resources is deprecated as of iOS 27 and should not be the foundation
of a new implementation.

Source: [Apple Background Assets](https://developer.apple.com/documentation/backgroundassets/downloading-apple-hosted-asset-packs)

## Android

Android 12/API 31 added a factory for an explicitly on-device recognizer:

- Check `SpeechRecognizer.isOnDeviceRecognitionAvailable(context)`.
- Use `SpeechRecognizer.createOnDeviceSpeechRecognizer(context)` only when the
  check succeeds.
- Destroy the recognizer when finished.

Android 13/API 33 added recognition support queries, on-device model downloads,
formatting controls, and biasing strings. Android 14/API 34 added model-download
progress and more detailed language and word metadata.

Sources:

- [Android SpeechRecognizer](https://developer.android.com/reference/android/speech/SpeechRecognizer)
- [Android RecognizerIntent](https://developer.android.com/reference/android/speech/RecognizerIntent)
- [Android recognition support](https://developer.android.com/reference/android/speech/RecognitionSupport)

Android is fragmented by device manufacturer, installed recognition service,
and language-model availability. Some devices may not provide an on-device
recognizer. `EXTRA_PREFER_OFFLINE` on older Android versions is only a hint and
may be ignored, so it cannot support a strict offline privacy promise.

The Android SpeechRecognizer documentation also says the API is not intended
for indefinite continuous recognition. It is still suitable for Antgrid's
push-to-talk dictation flow.

## macOS

For Apple-silicon Macs running macOS 26+, SpeechAnalyzer and SpeechTranscriber
should be Antgrid's only initial macOS backend. Parakeet does not need to be
packaged for macOS unless field data reveals an important unsupported locale or
quality problem.

Apple silicon is not itself the complete compatibility contract. The
implementation must check:

- The OS is macOS 26 or newer.
- `SpeechTranscriber.isAvailable` is true.
- `SpeechTranscriber.supportedLocale(equivalentTo:)` returns a locale.
- AssetInventory can install or locate the required assets.
- Microphone and speech permissions have been granted.

If Antgrid retains support for macOS 15 or earlier, use SFSpeechRecognizer only
when it reports on-device support, disable voice input on unsupported systems,
or add Parakeet as an optional fallback. Raising voice input itself to require
macOS 26 is simpler than making the entire application require macOS 26.

## Windows

### Production API currently available

`Windows.Media.SpeechRecognition` is stable but is not a suitable private
free-form dictation backend. Its dictation and web-search topic grammars use a
remote Microsoft service and require Online speech recognition to be enabled.
Only constrained list and SRGS grammars are processed locally. The API also
requires MSIX package identity.

Sources:

- [Windows speech recognition](https://learn.microsoft.com/en-us/windows/apps/develop/input/speech-recognition)
- [Windows recognition constraints](https://learn.microsoft.com/en-us/windows/apps/develop/input/define-custom-recognition-constraints)

### New on-device Windows AI Speech API

`Microsoft.Windows.AI.Speech` provides the capabilities Antgrid needs:

- Fully on-device recognition.
- Batch and continuous streaming recognition.
- NPU execution on Copilot+ PCs.
- CPU execution on other compatible machines.
- A model preinstalled on Copilot+ PCs or downloaded through Windows Update for
  CPU devices.

Its documented platform requirements include Windows 11 24H2/build 26100 or
later, MSIX package identity, and the `systemAIModels` capability. The app must
query `SpeechRecognitionModel.GetReadyState()` and use `EnsureReadyAsync()`
after obtaining user consent for a model download.

Source: [Windows AI Speech Recognition](https://learn.microsoft.com/en-us/windows/ai/apis/speech-recognition)

As of the verification date, this API remains experimental despite the polished
feature guide:

- It was introduced in Windows App SDK 2.2 Experimental 9 under "Speech
  Recognition APIs [Experimental]."
- Public API types carry `Windows.Foundation.Metadata.Experimental`.
- The API reference identifies Windows App SDK 2.0 Experimental as the
  applicable product.
- Microsoft states that experimental-channel APIs are unsupported for
  production and apps using them cannot be published to the Microsoft Store.

Sources:

- [Windows App SDK release notes](https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/release-notes/windows-app-sdk-2-0)
- [Microsoft.Windows.AI.Speech API reference](https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/microsoft.windows.ai.speech?view=windows-app-sdk-2.0-experimental)
- [Windows AI API troubleshooting](https://learn.microsoft.com/en-us/windows/ai/apis/troubleshooting)

The implementation can be prototyped behind a development flag, but Antgrid
should not depend on it in a production release until Microsoft ships it in the
stable channel without Experimental metadata.

### Windows version availability

"Windows 11" does not imply 24H2 or newer. As of the verification date, Home
and Pro 23H2 have reached end of support, but Enterprise and Education 23H2
remain supported until 2026-11-10. Managed update deferrals, compatibility
safeguard holds, stale installations, and unsupported installations also leave
some Windows 11 machines below 24H2.

Sources:

- [Supported Windows client versions](https://learn.microsoft.com/en-us/windows/release-health/supported-versions-windows-client)
- [Windows safeguard holds](https://learn.microsoft.com/en-us/windows/deployment/update/safeguard-holds)

Even when Antgrid eventually requires Windows 11 24H2, it must capability-check
the API, packaging identity, model state, and hardware at runtime.

## Proposed Antgrid architecture

Use a single application-level contract implemented by platform adapters:

```text
SpeechInputBackend
  availability
  privacyMode
  supportedLocales
  supportsStreaming
  supportsPunctuation
  start
  stop
  cancel
  partialTranscript
  finalTranscript
  endOfUtterance
```

Suggested adapters:

```text
AppleSpeechAnalyzerBackend
AppleLegacySpeechBackend
AndroidOnDeviceSpeechBackend
SherpaParakeetBackend
WindowsAISpeechBackend (disabled until stable)
```

The Flutter layer should own the composer state and review-before-send behavior.
Platform adapters should return partial and finalized text without knowing how
the agent session is routed.

For native backends, expose the actual privacy state rather than a generic
"native" label:

- On-device and ready.
- On-device model download required.
- On-device unavailable for this locale or device.
- Network recognition available but disabled by Antgrid policy.

Repository and coding vocabulary can improve recognition. Apple supports
contextual strings and custom vocabulary; modern Android recognizers accept
biasing strings. Candidate terms include the project name, agent names, common
CLI tools, and a bounded selection of project symbols. Do not transmit a full
repository symbol index to a recognizer that is not explicitly on-device.

## Security and product requirements

- Never auto-submit a voice transcript in the initial release.
- Keep raw audio in memory and do not log or persist it by default.
- Do not log full transcripts in production diagnostics.
- Clearly distinguish on-device recognition from any network backend.
- Never silently downgrade an on-device request to cloud recognition.
- Require explicit microphone permission and provide a visible recording state.
- Apply the same account membership, machine remote-access switch, and project
  catalog authorization that protect other remote command-input paths if audio
  or transcript data ever crosses to the bridge.
- Prefer transcription on the UI device. This avoids adding audio frames to the
  relay protocol and keeps the relay zero-knowledge without extra machinery.
- Keep the native runtime and model downloader versioned independently from the
  voice UI so backends can be replaced without protocol churn.

## Suggested delivery sequence

1. Build the backend-neutral Flutter interface and push-to-talk composer UX.
2. Implement Apple SpeechAnalyzer for macOS 26 and iOS/iPadOS 26.
3. Implement Android's explicit on-device SpeechRecognizer with capability and
   model-download handling.
4. Benchmark Parakeet TDT v3 INT8 with sherpa-onnx on representative Windows
   hardware, including cold start, utterance latency, peak RAM, and coding-term
   accuracy.
5. Ship Parakeet as an optional Windows model download with checksum validation
   and removal controls.
6. Keep Microsoft.Windows.AI.Speech behind a development flag and reevaluate it
   when Microsoft publishes a stable SDK surface.
7. Test with a corpus of real coding prompts, paths, flags, acronyms, and agent
   instructions rather than relying only on general ASR benchmarks.

## UI and UX research: terminal and chat modes

### Product decision

Ship dictation, not hands-free voice conversation, in the first release. Speech
becomes editable text; it never submits a chat message, presses Return in a
terminal, or answers an approval automatically.

| Surface | While listening | Recognition result | User commit |
| --- | --- | --- | --- |
| Chat | Provisional text at the composer caret | Final text joins the draft as one undoable edit | Existing Send action |
| Terminal | Provisional text in a review shelf outside the PTY | Final text remains editable in the shelf | Insert types it without Return |

This distinction follows Antgrid's current UI. Chat owns a persistent rich-text
composer. Terminal mode sends raw input into a PTY, where an incorrect interim
token could alter a shell command, answer an approval prompt, or drive a TUI
before the recognizer corrects it. Never stream partial ASR results into a PTY.

### Comparable-product findings

- VS Code inserts dictation into chat without submitting it, Escape cancels the
  current dictation, and holding the shortcut provides push-to-talk. Terminal
  dictation waits for a final result before insertion.
  [VS Code voice support](https://code.visualstudio.com/docs/configure/accessibility/voice)
- The GitHub Copilot app downloads a local model and inserts transcription into
  the prompt box for review before send.
  [GitHub Copilot app voice dictation](https://docs.github.com/en/copilot/how-tos/github-copilot-app/agent-sessions#using-voice-dictation)
- Orca supports toggle and hold modes, microphone selection, local and cloud
  models, system-microphone fallback with a notice, and a visible Listening
  pill with Stop. [Orca voice settings](https://www.onorca.dev/docs/settings#voice)
- ChatGPT returns an editable transcript before it is sent and distinguishes
  dictation from live voice conversation.
  [ChatGPT dictation FAQ](https://help.openai.com/en/articles/12168547-voice-dictation-faq)
- Apple Dictation and Gboard support mixed typing/dictation and spoken editing
  or punctuation on some devices and languages. These commands vary by
  platform, so Antgrid must not silently turn phrases such as "send", "run",
  "yes", or "approve" into actions.
  [Apple iPhone dictation](https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios),
  [Gboard advanced voice typing](https://support.google.com/gboard/answer/11197787)

The consistent pattern is staged text plus explicit confirmation.

### Chat-mode design

Put the microphone in the composer's lower control row beside Attach. Do not
place it beside or replace the far-right Send/Stop control: while an agent is
running that control stops the agent, which is unrelated to stopping recording.

~~~text
+------------------------------------------------------------+
| > Existing draft [provisional dictated text...]            |
| [attach] [mic/listening]  model  effort  mode       [send] |
+------------------------------------------------------------+
~~~

- A tap starts toggle-mode dictation at the current selection. First use
  explains the backend and privacy boundary before requesting permission.
- Interim results replace one provisional, accent-underlined span at the caret;
  they do not create repeated undo-history entries.
- The final result commits as one edit. One Undo removes the dictated segment.
- Stop keeps the result. Cancel or Escape removes only this dictation's text and
  restores the pre-dictation selection.
- Never clear or rewrite an existing draft. Add boundary whitespace only when
  grammar requires it.
- If the user types while listening, finalize the provisional segment before
  applying the edit. If that is not reliable in v1, stop and keep the text on
  the first manual edit rather than locking the composer.
- While recognition is finalizing, Send stops recognition and waits; it does not
  also submit in the same gesture.
- Slash-command and file-mention suggestions react only to committed text.
- Cover empty and non-empty drafts, selections, attachments, pending prompts,
  and both idle and running agents.

### Terminal-mode design

On mobile, pin Dictate beside the existing pinned Keyboard toggle in the quick
action bar, outside its horizontal shortcut scroller. On desktop, provide a
remappable shortcut and a visible compact mic action associated with the active
agent terminal. Both open the same review shelf.

~~~text
+-------------------- active terminal / PTY ------------------+
| agent output and prompt                                     |
+---------------- dictation review shelf ---------------------+
| Listening 00:12   explain the failing test...              |
| [Cancel]                                      [Stop/Insert] |
+-------------------------------------------------------------+
| [attach] [Tab] [Esc] ...                    [mic] [keyboard]|
+-------------------------------------------------------------+
~~~

- The shelf is an editable text surface outside Ghostty. It shows interim text
  while listening and the editable final transcript after recognition.
- The primary action is Stop while listening and Insert after finalization.
- Insert uses the existing terminal input/refusal path after sanitizing control
  characters and line endings. It never appends Return or another submit key.
- A pause or end-of-utterance event never becomes terminal Return. Preserve an
  intentional newline only after an explicit phrase such as "new line".
- Bind capture to its originating session and terminal ID. A later focus, mode,
  or session change must never redirect it to a different terminal.
- If the origin exits, disconnects, becomes input-paused, or loses permission,
  retain the text and offer Copy/Retry rather than discarding it.
- Scrollback keeps its existing input protections and may close only after
  explicit Insert through the established input path.
- Do not infer whether the screen is an agent prompt, shell, approval menu,
  password prompt, or TUI, and do not auto-run anything.

VS Code performs command-line-specific cleanup for terminal dictation. Antgrid
should initially preserve normal prose and punctuation because terminal mode is
often an agent prompt. Spoken-symbol conversion can be added later as long as
the transformed text remains visible before Insert.

### Shared state model

Only one microphone session may exist across the app:

~~~text
unavailable
  -> setup required -> downloading/preparing -> idle
idle
  -> requesting permission -> listening -> finalizing -> review/idle
listening
  -> cancelled -> idle
  -> interrupted/error -> review when text exists, otherwise idle
~~~

| State | Visible indication | Actions |
| --- | --- | --- |
| Setup required | On-device setup, download size, language, privacy | Set up, Not now |
| Downloading | Model, bytes/percent, network recommendation | Cancel |
| Preparing | Preparing dictation... | Cancel |
| Permission denied | Microphone access is off | Open settings, Cancel |
| Listening, no speech | Listening... and elapsed time | Stop, Cancel |
| Listening, speech | Interim text and modest level/pulse feedback | Stop, Cancel |
| Finalizing | Finishing transcript... while text remains visible | Cancel |
| Review | Editable final text | Send in chat; Insert/Cancel in terminal |
| Recoverable error | Plain reason without erasing captured text | Retry, Copy, Cancel |

Do not use a spinner alone because it cannot distinguish model preparation,
listening, and finalization. Use a real input-level meter only if the backend
provides amplitude; otherwise show a recording dot rather than a fake waveform.
Respect reduced-motion settings.

### Shortcuts and gestures

Support two user-selectable modes:

- Toggle: activate once to start and again to stop. This is the touch and
  switch-access default.
- Hold to talk: hold a remappable hardware shortcut and release to stop, then
  review. It is faster for short prompts but must not be the only interaction.

Audit Antgrid's keymap and host OS shortcuts before choosing a default chord.
Windows reserves Win+H for system voice typing and macOS Dictation shortcuts are
configurable. Keep stable action names even if bindings change: Start/stop
dictation, Cancel dictation, Insert terminal transcript, and Choose microphone.

### First use and settings

The first microphone tap should show a small contextual setup panel explaining:

- whether transcription is on device;
- that raw audio is not saved by default;
- the approximate one-time model download size;
- the recognition language; and
- that Antgrid never sends or runs the result automatically.

Prepare or download the model before asking for microphone permission, then ask
when the user is ready to record. Apple asks for a specific purpose string, and
Android recommends tying a runtime permission to the action that needs it rather
than asking at startup.
[Apple privacy guidance](https://developer.apple.com/design/human-interface-guidelines/privacy),
[Android runtime-permission guidance](https://developer.android.com/training/permissions/requesting)

Voice settings should contain:

- Enable dictation.
- Recognition language, with Auto showing its resolved language.
- Input device where the platform exposes multiple microphones.
- Toggle or hold-to-talk mode.
- Active backend with an explicit On device or Uses network privacy label.
- Model status, version, size, Download/Update/Remove, and storage location.
- Silence timeout, including Off.
- Optional interim-transcript display.
- A microphone test that shows level without storing audio.

Never silently fall back from on-device to a network recognizer. Falling back
from a removed microphone to the system default is acceptable only with a
notice naming the newly selected device.

### Coding-language recognition

- Bias with the active project and agent names, recently visible paths, common
  tools, and a small bounded vocabulary of repository symbols.
- Mark low-confidence words if the backend exposes confidence and offer
  alternatives on tap or click.
- Support explicit text transformations such as new line, slash, dash,
  underscore, open paren, and close paren.
- Never map send, enter, run, approve, yes, or no to UI or terminal actions in
  v1; they are ordinary coding-prompt content.
- Keep personal custom terms local. Do not send workspace vocabulary to a
  network recognizer without explicit disclosure.

### Accessibility and feedback

- Use at least a 44 by 44 point hit region on Apple touch platforms and 48 by
  48 dp on Android; the visible glyph may be smaller.
  [Apple button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons),
  [Android accessibility guidance](https://developer.android.com/guide/topics/ui/accessibility/views/apps-views)
- Give the button stateful labels: Start dictation, Stop dictation, and
  Dictation unavailable: reason. Never expose an unlabeled microphone.
- Announce meaningful transitions only: listening, stopped, inserted,
  permission denied, and failure. Do not announce every interim word. Expose
  status without moving focus.
  [WCAG status-message guidance](https://www.w3.org/WAI/WCAG21/Understanding/status-messages)
- Keep focus in the chat composer. In terminal mode, move focus to the review
  shelf only when the user elects to edit it.
- Pair optional sounds or haptics with a persistent visual recording state.
- Show an in-app recording indicator even when the OS also shows one. Android
  explicitly recommends real-time in-app indication for sensitive sensor use.
  [Android privacy checklist](https://developer.android.com/privacy-and-security/about)
- Test VoiceOver, TalkBack, Narrator, keyboard-only use, switch access, large
  text, high contrast, and reduced motion.

### Interruptions and recovery

- Only one recognizer may own the microphone. Starting another capture stops
  and preserves the first result rather than silently replacing it.
- On backgrounding, audio-route loss, phone call, screen lock, or revoked
  permission, stop capture immediately and preserve usable text for review.
- No speech leaves the prior draft untouched and reports No speech detected.
- Recognition failure after partial text preserves it as incomplete and offers
  Retry, Copy, or Cancel.
- Switching project or session stops recognition and stores the result with the
  origin; a notice identifies where it was saved.
- Disable language and backend changes while listening.
- Never record in the background. Release the microphone promptly after Stop,
  Cancel, finalization, or error.

### Recommended v1 scope

1. One microphone session manager and the shared state model.
2. Chat mic beside Attach, provisional inline text, Stop, Escape-to-cancel,
   one-step Undo, and never auto-send.
3. Terminal review shelf, pinned mobile mic, desktop action and shortcut,
   explicit Insert without Return, and retained text on refusal.
4. Contextual setup, privacy labeling, model progress, permission recovery, and
   microphone selection where supported.
5. Toggle and hold modes, accessibility semantics, and interruption handling.

Defer wake words, spoken agent responses, hands-free conversation, LLM transcript
rewriting, automatic command execution, and voice-driven approvals. Those need
different privacy, interruption, and safety models.
