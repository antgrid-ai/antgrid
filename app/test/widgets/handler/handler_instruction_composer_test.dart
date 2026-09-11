// The one box Handler instructions are typed into, shared by the arm sheet and
// the backlog drawer. The rules pinned here are the ones the two hosts must not
// be able to answer differently: what a return key does, when the send key is
// live, and who owns the text.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_composer_send_button.dart';
import 'package:antgrid/design/widgets/ab_prompt_field.dart';
import 'package:antgrid/widgets/handler/handler_instruction_composer.dart';
import 'package:antgrid/widgets/handler/handler_judge_chip.dart';
import 'package:antgrid/widgets/handler/handler_session_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

final _field = find.byKey(const Key('handler-instruction-field'));
final _sendKey = find.byKey(const Key('handler-instruction-send'));

/// The controller is HOST-owned, so the tests own it too — which is the point:
/// nothing the composer does may clear or dispose it.
Future<TextEditingController> _pump(
  WidgetTester tester, {
  VoidCallback? onSend,
  String text = '',
}) async {
  useInMemoryPrefs();
  final controller = TextEditingController(text: text);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Scaffold(
          body: HandlerInstructionComposer(
            terminalId: 't1',
            controller: controller,
            hintText: 'Send an instruction…',
            judge: (judgeTool: null, judgeModel: null),
            onJudgeChanged: (_) {},
            judgeScopeNote: handlerJudgeScopeNextPass,
            send: onSend == null
                ? null
                : HandlerComposerSend(
                    tooltip: 'Send to Handler',
                    semanticLabel: 'Send to Handler',
                    onSend: onSend,
                  ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

/// Types into the field, which also gives it the focus every key test needs —
/// the Enter policy lives on the composer's own [FocusNode].
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(_field, text);
  await tester.pump();
}

void main() {
  group('the return key', () {
    testWidgets('hardware Enter commits through the host verb', (tester) async {
      var sends = 0;
      final controller = await _pump(tester, onSend: () => sends++);
      await _type(tester, 'also update the docs');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sends, 1);
      // Clearing is a statement that the send happened, which only the host
      // knows — so the composer leaves the words exactly where they were.
      expect(controller.text, 'also update the docs');
    });

    testWidgets('Shift+Enter writes a newline and commits nothing', (
      tester,
    ) async {
      var sends = 0;
      final controller = await _pump(tester, onSend: () => sends++);
      await _type(tester, 'first line');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      await tester.pump();

      expect(sends, 0);
      expect(controller.text, 'first line\n');
    });

    testWidgets('Ctrl+Enter commits even mid-paragraph', (tester) async {
      var sends = 0;
      await _pump(tester, onSend: () => sends++);
      await _type(tester, 'also update the docs');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(sends, 1);
    });

    testWidgets('on a host with no send verb, Enter is a newline', (
      tester,
    ) async {
      // The arm sheet's shape: its one commit is [Arm Handler], so a return key
      // here must not look like it promises anything.
      final controller = await _pump(tester);
      await _type(tester, 'also update the docs');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(controller.text, 'also update the docs\n');
      expect(find.byType(ComposerSendButton), findsNothing);
    });

    testWidgets('Enter on an empty field neither sends nor is swallowed', (
      tester,
    ) async {
      var sends = 0;
      final controller = await _pump(tester, onSend: () => sends++);
      await _type(tester, '   ');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(sends, 0);
      // A send this surface cannot make falls back to the newline rather than
      // to nothing: a field that swallowed the key would look frozen.
      expect(controller.text, '   \n');
    });

    testWidgets('the field carries no send action for a soft keyboard', (
      tester,
    ) async {
      // The whole point of dropping `TextInputAction.send`: on a phone Enter
      // must insert a newline and the send key must be the only commit. With
      // maxLines null and no explicit action, the platform gives us newline.
      await _pump(tester, onSend: () {});
      final field = tester.widget<TextField>(
        find.descendant(of: _field, matching: find.byType(TextField)),
      );
      expect(field.textInputAction, isNull);
      expect(field.maxLines, isNull);
    });
  });

  group('the send key', () {
    testWidgets('is dead while the field holds only whitespace', (
      tester,
    ) async {
      await _pump(tester, onSend: () {});
      await _type(tester, '   ');

      expect(tester.widget<ComposerSendButton>(_sendKey).onTap, isNull);

      await _type(tester, '   x');

      expect(tester.widget<ComposerSendButton>(_sendKey).onTap, isNotNull);
    });

    testWidgets('opens dead on an empty host controller', (tester) async {
      await _pump(tester, onSend: () {});
      expect(tester.widget<ComposerSendButton>(_sendKey).onTap, isNull);
    });

    testWidgets('opens live on a controller the host seeded', (tester) async {
      await _pump(tester, onSend: () {}, text: 'carried over');
      expect(tester.widget<ComposerSendButton>(_sendKey).onTap, isNotNull);
    });

    testWidgets('a tap commits without touching the words', (tester) async {
      var sends = 0;
      final controller = await _pump(tester, onSend: () => sends++);
      await _type(tester, 'also update the docs');

      await tester.tap(_sendKey);
      await tester.pump();

      expect(sends, 1);
      expect(controller.text, 'also update the docs');
    });
  });

  group('the box', () {
    testWidgets('opens at three lines and stops growing at the cap', (
      tester,
    ) async {
      final controller = await _pump(tester, onSend: () {});
      expect(tester.widget<AbPromptField>(_field).minLines, 3);

      controller.text = [for (var i = 0; i < 40; i++) 'line $i'].join('\n');
      await tester.pumpAndSettle();

      // A long instruction scrolls inside the box rather than pushing the
      // backlog list — or the arm sheet's own commit — off screen.
      expect(tester.getSize(_field).height, lessThanOrEqualTo(176.0));
    });

    testWidgets('carries the judge that will read what is typed', (
      tester,
    ) async {
      await _pump(tester, onSend: () {});
      expect(find.byType(HandlerJudgeChip), findsOneWidget);
    });
  });
}
