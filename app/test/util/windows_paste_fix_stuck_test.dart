// Deliberately its own file, not folded into windows_paste_fix_test.dart:
// WindowsPasteFix.install() guards itself with a static `_installed` flag
// meant to survive the app's whole lifetime, but flutter_test gives every
// testWidgets its own fresh FocusManager.instance — so a SECOND test in the
// same file calling install() again is a no-op that leaves this test's
// FocusManager with no handler registered at all, and the assertions below
// fail for a reason that has nothing to do with the fix under test. A
// separate file gets its own isolate, and so its own untouched `_installed`.
import 'dart:ui' as ui;

import 'package:antgrid/util/windows_paste_fix.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'an injected paste (real Ctrl-down, no matching real Ctrl-up) does not '
    'leave Ctrl stuck for a later bare "v"',
    (tester) async {
      // Regression test: Windows' clipboard history (Win+V) injects a Ctrl+V
      // chord whose Ctrl-down arrives as a real (non-synthesized) event, but
      // is immediately followed by a SYNTHESIZED corrective key-up the
      // embedder issues after resyncing against GetKeyState — before the V
      // arrives. `_track` only records non-synthesized events, so the mirror
      // correctly reads Ctrl as held for the V that follows. The bug: nothing
      // ever cleared that recorded "held" afterward, because no REAL key-up
      // ever comes for a key that was never physically pressed — so every
      // later bare "v" misread as Ctrl+V and re-pasted instead of typing.
      var reads = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return {'text': 'hello'};
          }
          if (call.method == 'Clipboard.hasStrings') return {'value': true};
          return null;
        },
      );
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      WindowsPasteFix.install();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(controller: controller, autofocus: true),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      // The embedder's own corrective resync — synthesized, so `_track`
      // ignores it, but it's what makes `HardwareKeyboard.isControlPressed`
      // read false for the very V event that needs it. `keyEventManager` is
      // the only door a synthesized event can come through in a test —
      // `HardwareKeyboard.addHandler` receives events rather than injecting
      // them, and updating `HardwareKeyboard` alone would never reach the
      // focus-manager handler under test (mirrors the same helper in
      // terminal_view_wrapper_keys_test.dart).
      // ignore: deprecated_member_use
      ServicesBinding.instance.keyEventManager.handleKeyData(
        ui.KeyData(
          timeStamp: Duration.zero,
          type: ui.KeyEventType.up,
          logical: LogicalKeyboardKey.controlLeft.keyId,
          physical: PhysicalKeyboardKey.controlLeft.usbHidUsage,
          character: null,
          synthesized: true,
        ),
      );
      expect(HardwareKeyboard.instance.isControlPressed, isFalse);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV, character: 'v');
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(controller.text, 'hello');

      // No physical Ctrl was ever really released, and never will be — the
      // mirror must have spent its one-shot "held" reading on the paste
      // above, not left it stuck. A later bare "v" must not re-paste.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();
      expect(
        reads,
        1,
        reason:
            'a bare v after the injected paste must not re-paste — Ctrl must '
            'not still read as held',
      );
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
