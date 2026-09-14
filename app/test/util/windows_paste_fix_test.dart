import 'package:antgrid/util/windows_paste_fix.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Windows Ctrl+V pastes once and leaves plain V alone', (
    tester,
  ) async {
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
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(controller.text, 'hello');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.pumpAndSettle();
    expect(reads, 1);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
