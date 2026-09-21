# Voice input UI preview

The first implementation is a simulated dictation experience. It is visible in
debug builds and in the offline demo; normal release sessions do not expose it.
No audio is captured, no speech model is installed, and voice preferences and
transcripts stay in memory.

## Try it

Open a session in chat or terminal mode and select the microphone. In the setup
sheet, select a scenario, choose **Set up**, then **Allow & start (simulated)**.
Stop recording to see the final transcript. The settings gear reopens the
scenario selector. Preparation, permission denial, model download, unavailable
recognition, interruption, no speech, revised partials, long prompts, and
final-only recognition are simulated locally.

- Chat shows an underlined provisional span in a preview of the rich composer.
  Stop commits it to the original draft; Cancel restores the original selection
  and text. Manual editing ends capture and keeps the edited text. Sending is
  disabled during capture and finalization; stopping an agent remains separate.
- Terminal shows a bounded review shelf. Edit the final text and select Insert.
  Input uses the existing terminal service's authorization/refusal path. Line
  breaks become spaces, control characters are removed, and no Return is added.
  A refusal retains the text for Retry or Copy.
- Capture is bound to the original project/session/surface. Navigation or
  backgrounding stops it. Late events cannot change another capture's draft.
- Toggle is the default. Settings can bind a function key (F1–F12) and choose
  hold-to-talk. No key is reserved by default. Shortcuts apply while the relevant
  input is focused; Escape cancels capture before terminal handling.

The settings use an adaptive sheet and Antgrid controls. Language and microphone
are read-only because the fake backend exposes only English and simulated input.
Download progress is an illustrative 487 MB scenario, not actual storage use.

## Implementation boundary

`app/lib/voice/voice_input.dart` owns capture identity, state, in-memory drafts,
and the backend interface. The fake backend emits partial/final text and errors.
`voice_composer_binding.dart` keeps provisional revisions out of the original
rich document and its undo history. `voice_widgets.dart` supplies shared controls,
setup/recovery UI, the terminal shelf, and the chat editor binding.

Native recognition, actual permission/device management, vocabulary biasing,
model downloads, and performance evaluation remain the next integration phase.
Production rollout also needs real-device keyboard, screen-reader, audio-route,
and lifecycle verification across the supported operating systems.

## Verification

Run the focused tests from `app/`:

```text
flutter test --no-pub -j 2 test/voice test/widgets/transcript/composer/composer_controller_test.dart test/widgets/terminal_quick_actions_bar_test.dart
flutter analyze
```

Run `npm run check:font-tokens` from the repository root. Do not run multiple
Flutter/Dart analysis processes concurrently.
