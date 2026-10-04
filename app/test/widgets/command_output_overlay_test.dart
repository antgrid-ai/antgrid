import 'dart:async';

import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/command_models.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/command_output_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _focus = NotifierProvider<ValueController<String>, String>(
  () => ValueController<String>('a'),
);

CommandState _state(CommandStatus status, String output) =>
    _running(CommandOutput()..append(output), status: status);

CommandOutput _lines(
  int count, {
  required int blockChars,
  int maxChars = kCommandOutputMaxChars,
  String word = 'line',
}) {
  final output = CommandOutput(blockChars: blockChars, maxChars: maxChars);
  for (var i = 0; i < count; i++) {
    output.append('$word ${i.toString().padLeft(2, '0')}\n');
  }
  return output;
}

CommandState _running(
  CommandOutput output, {
  CommandStatus status = CommandStatus.running,
}) => CommandState(
  current: CommandExecution(
    commandName: 'test',
    projectId: 'p',
    status: status,
    output: output,
  ),
);

ThemeData _theme() => ThemeData.dark().copyWith(
  extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
);

Future<StreamController<CommandState>> _pumpOverlay(WidgetTester tester) async {
  final controller = StreamController<CommandState>.broadcast();
  addTearDown(controller.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        commandStateProvider.overrideWith((ref) => controller.stream),
        selectedRegistrationIdProvider.overrideWithValue('p'),
        focusedCheckoutIdProvider.overrideWith((ref) => 'a'),
        terminalStateProvider.overrideWith(
          (ref) => const Stream<TerminalState>.empty(),
        ),
      ],
      child: MaterialApp(
        theme: _theme(),
        home: const Scaffold(body: Stack(children: [CommandOutputOverlay()])),
      ),
    ),
  );
  return controller;
}

Future<void> _show(
  WidgetTester tester,
  StreamController<CommandState> controller,
  CommandState state,
) async {
  controller.add(state);
  await tester.pump();
  await tester.pump();
}

// Under a selection registrar a Text builds MouseRegion > ... > RichText, so
// the render object of the Text itself is not the paragraph.
RenderParagraph _paragraphOf(WidgetTester tester, String text) =>
    tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text(text, skipOffstage: false),
        matching: find.byType(RichText),
        skipOffstage: false,
      ),
    );

void main() {
  // The provider follows focus, so states before and after a checkout switch
  // are two commands; reading them as one would dismiss the landed result.
  testWidgets('a checkout switch is not read as a command finishing', (
    tester,
  ) async {
    final a = StreamController<CommandState>.broadcast();
    final b = StreamController<CommandState>.broadcast();
    addTearDown(a.close);
    addTearDown(b.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          commandStateProvider.overrideWith(
            (ref) => ref.watch(_focus) == 'a' ? a.stream : b.stream,
          ),
          selectedRegistrationIdProvider.overrideWithValue('p'),
          focusedCheckoutIdProvider.overrideWith((ref) => ref.watch(_focus)),
          terminalStateProvider.overrideWith(
            (ref) => const Stream<TerminalState>.empty(),
          ),
        ],
        child: MaterialApp(
          theme: _theme(),
          home: const Scaffold(
            body: Stack(children: [CommandOutputOverlay()]),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(CommandOutputOverlay)),
    );

    a.add(_state(CommandStatus.running, 'a is building'));
    await tester.pump();
    await tester.pump();
    expect(find.text('a is building'), findsOneWidget);

    container.read(_focus.notifier).set('b');
    await tester.pump();
    b.add(_state(CommandStatus.success, 'b finished long ago'));
    await tester.pump();
    await tester.pump();

    // Still expanded: nothing finished in front of the user.
    expect(find.text('b finished long ago'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('b finished long ago'), findsOneWidget);
  });

  testWidgets('new output re-lays-out only the tail, even as the oldest '
      'blocks are trimmed', (tester) async {
    final output = _lines(30, blockChars: 32, maxChars: 512)..append('z' * 40);
    final controller = await _pumpOverlay(tester);
    await _show(tester, controller, _running(output));

    Text textOf(String text) =>
        tester.widget<Text>(find.text(text, skipOffstage: false));
    final survivor = output.blocks.last;
    final survivorText = textOf(survivor);
    final paragraph = _paragraphOf(tester, survivor);
    final seq = output.firstBlockSeq;

    // Unterminated, so nothing seals: a new selectable would join in the
    // build-only frame below, before its paragraph has been laid out.
    for (var i = 0; i < 64 && output.firstBlockSeq == seq; i++) {
      output.append('z' * 8);
    }
    expect(output.firstBlockSeq, greaterThan(seq));
    expect(identical(output.blocks.last, survivor), isTrue);

    await tester.pump(null, EnginePhase.build);

    expect(identical(textOf(survivor), survivorText), isTrue);
    expect(identical(_paragraphOf(tester, survivor), paragraph), isTrue);
    expect(paragraph.debugNeedsLayout, isFalse);
    expect(_paragraphOf(tester, output.tail).debugNeedsLayout, isTrue);

    await tester.pump();
  });

  testWidgets('output split into blocks renders at the height of one paragraph', (
    tester,
  ) async {
    final output = CommandOutput(blockChars: 24);
    output.append('first line\nsecond line\r\n\n\n');
    output.append('${'long soft wrapping words ' * 30}\r\n');
    output.append('\r\n\r\nmiddle\n\n');
    output.append('crlf one\r\ncrlf two\r\n\r\ncrlf three\r\n');
    output.append('end of output');
    expect(output.trimmed, isFalse);
    expect(output.blocks.length, greaterThan(2));

    final controller = await _pumpOverlay(tester);
    await _show(tester, controller, _running(output));

    final area = find.byType(SelectionArea, skipOffstage: false);
    final h = tester.getSize(area).height;
    final w = tester.getSize(area).width;
    final text = output.text;

    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: w,
              child: Text(
                text,
                style: AbTokens.monoStyle(
                  fontSize: AbTokens.fontMd,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final single = tester.getSize(find.byType(Text).first).height;
    expect(h, closeTo(single, 0.01));
  });

  testWidgets('trimmed output says so, and the note is not copied', (
    tester,
  ) async {
    final output = _lines(40, blockChars: 32, maxChars: 128);
    expect(output.trimmed, isTrue);
    final controller = await _pumpOverlay(tester);
    await _show(tester, controller, _running(output));

    expect(
      find.text('Earlier output trimmed', skipOffstage: false),
      findsOneWidget,
    );

    String? copied;
    _watchClipboard((text) => copied = text);
    await _invokeOnTail(
      tester,
      output,
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
    );
    await _invokeOnTail(tester, output, CopySelectionTextIntent.copy);

    expect(copied, output.text);
  });

  testWidgets('a selection survives the oldest blocks being trimmed', (
    tester,
  ) async {
    final output = _lines(20, blockChars: 32, maxChars: 256);
    final controller = await _pumpOverlay(tester);
    await _show(tester, controller, _running(output));
    await _invokeOnTail(
      tester,
      output,
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
    );

    final firstBefore = output.firstBlockSeq;
    for (var n = 20; n < 50; n++) {
      output.append('line $n\n');
    }
    expect(output.firstBlockSeq, greaterThan(firstBefore));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);

    String? copied;
    _watchClipboard((text) => copied = text);
    await _invokeOnTail(tester, output, CopySelectionTextIntent.copy);
    expect(
      copied == null || output.text.contains(copied!),
      isTrue,
      reason: 'copied: $copied',
    );
  });

  testWidgets('a new run shows only its own output', (tester) async {
    final a = _lines(4, blockChars: 16, word: 'alpha');
    final b = _lines(4, blockChars: 16, word: 'beta ');
    final controller = await _pumpOverlay(tester);

    await _show(tester, controller, _running(a));
    expect(find.text(a.blocks.first, skipOffstage: false), findsOneWidget);

    await _show(tester, controller, _running(b));
    expect(find.textContaining('alpha', skipOffstage: false), findsNothing);
    expect(find.text(b.blocks.first, skipOffstage: false), findsOneWidget);
  });

  test('sending trimmed output tells the agent it was trimmed', () {
    final trimmed = _lines(40, blockChars: 32, maxChars: 128);
    expect(trimmed.trimmed, isTrue);
    expect(
      commandOutputForAgent(trimmed),
      '[earlier output trimmed]\n${trimmed.text}',
    );

    expect(commandOutputForAgent(CommandOutput()..append('boom')), 'boom');
  });
}

void _watchClipboard(void Function(String? text) onCopy) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          onCopy((call.arguments as Map)['text'] as String?);
        }
        return null;
      });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });
}

Future<void> _invokeOnTail(
  WidgetTester tester,
  CommandOutput output,
  Intent intent,
) async {
  Actions.invoke(
    tester.element(find.text(output.tail, skipOffstage: false)),
    intent,
  );
  await tester.pump();
}
