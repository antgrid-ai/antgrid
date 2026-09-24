// Enter confirms and Esc cancels — except that Enter alone may never confirm a
// destructive action, and Enter on a Tab-focused button presses that button.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_confirm_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Future<bool>> open(
    WidgetTester tester, {
    bool destructive = false,
    String? confirmWord,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    final result = AbConfirmDialog.show(
      context: tester.element(find.byType(Scaffold)),
      title: 'Switch?',
      body: 'Body',
      confirmLabel: 'Switch',
      destructive: destructive,
      confirmWord: confirmWord,
    );
    await tester.pumpAndSettle();
    return result;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  testWidgets('Enter confirms', (tester) async {
    final result = await open(tester);
    await press(tester, LogicalKeyboardKey.enter);
    expect(await result, isTrue);
  });

  testWidgets('Esc cancels', (tester) async {
    final result = await open(tester);
    await press(tester, LogicalKeyboardKey.escape);
    expect(await result, isFalse);
  });

  testWidgets('Enter alone never confirms a destructive action', (
    tester,
  ) async {
    await open(tester, destructive: true);
    await press(tester, LogicalKeyboardKey.enter);
    expect(find.byType(AbConfirmDialog), findsOneWidget);
  });

  testWidgets('Enter submits a destructive action once its word is typed', (
    tester,
  ) async {
    final result = await open(tester, destructive: true, confirmWord: 'delete');
    await tester.enterText(find.byType(EditableText), 'delete');
    await tester.pump();
    await press(tester, LogicalKeyboardKey.enter);
    expect(await result, isTrue);
  });

  testWidgets('Enter on a focused Cancel cancels', (tester) async {
    final result = await open(tester);
    // Close (title) → Cancel.
    await press(tester, LogicalKeyboardKey.tab);
    await press(tester, LogicalKeyboardKey.tab);
    await press(tester, LogicalKeyboardKey.enter);
    expect(await result, isFalse);
  });
}
