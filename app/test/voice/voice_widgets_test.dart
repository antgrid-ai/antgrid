import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/voice/voice_input.dart';
import 'package:antgrid/voice/voice_widgets.dart';
import 'package:antgrid/widgets/transcript/composer/composer_controller.dart';
import 'package:antgrid/widgets/transcript/composer/rich_composer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const target = (project: 'local', session: 'one', surface: 'terminal');

Widget host(VoiceInputController c, Widget child, {bool enabled = true}) =>
    ProviderScope(
      overrides: [
        voiceInputProvider.overrideWithValue(c),
        voicePreviewEnabledProvider.overrideWithValue(enabled),
      ],
      child: MaterialApp(
        theme: buildAbTheme(),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'unmounting chat preserves transcript without poisoning next capture',
    (tester) async {
      final c = VoiceInputController()
        ..ready = true
        ..permission = true;
      final input = ComposerController();
      await tester.pumpWidget(
        host(
          c,
          VoiceChatEditor(
            target: target,
            controller: input,
            builder: (controller) =>
                RichComposer(controller: controller, onSend: () {}),
          ),
        ),
      );
      c.start(target);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(c.active, isNull);
      expect(input.isEmpty, false);
      expect(c.draft(target).text, isEmpty);
      expect(tester.takeException(), isNull);
      c.dispose();
      input.dispose();
    },
  );

  testWidgets('production gate hides preview controls', (tester) async {
    final c = VoiceInputController();
    await tester.pumpWidget(
      host(
        c,
        const Column(
          children: [
            VoiceMic(target: target),
            VoicePanel(target: target),
          ],
        ),
        enabled: false,
      ),
    );
    expect(find.byType(VoiceMic), findsOneWidget);
    expect(find.byTooltip('Start dictation (simulated)'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('terminal review survives refusal and sends no Return', (
    tester,
  ) async {
    final c = VoiceInputController()
      ..ready = true
      ..permission = true;
    var allow = false;
    final sent = <String>[];
    await tester.pumpWidget(
      host(
        c,
        Column(
          children: [
            const VoiceMic(target: target),
            VoicePanel(
              target: target,
              onInsert: (text) {
                sent.add(text);
                return allow;
              },
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Start dictation (simulated)'));
    await tester.pump(const Duration(seconds: 2));
    expect(sent, isEmpty);
    await tester.tap(find.text('Stop'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Insert'), findsOneWidget);
    await tester.tap(find.text('Insert'));
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
    expect(c.draft(target).text, isNotEmpty);
    allow = true;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(sent.length, 2);
    expect(
      sent.every((text) => !text.contains('\n') && !text.contains('\r')),
      true,
    );
    expect(find.text('Insert'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  testWidgets('chat preview commits final text without submitting', (
    tester,
  ) async {
    final c = VoiceInputController()
      ..ready = true
      ..permission = true;
    final input = ComposerController();
    var sends = 0;
    await tester.pumpWidget(
      host(
        c,
        VoiceChatEditor(
          target: target,
          controller: input,
          builder: (controller) =>
              RichComposer(controller: controller, onSend: () => sends++),
        ),
      ),
    );
    c.start(target);
    await tester.pump(const Duration(seconds: 2));
    expect(input.isEmpty, true);
    c.stop(target);
    await tester.pump(const Duration(seconds: 1));
    expect(input.toMarkdown(), SimulatedSpeechBackend.sample);
    expect(sends, 0);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    input.dispose();
  });

  testWidgets('setup and long review fit a narrow window with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = VoiceInputController();
    await tester.pumpWidget(
      host(
        c,
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(1.5),
          ),
          child: VoiceSetup(controller: c, target: target),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
