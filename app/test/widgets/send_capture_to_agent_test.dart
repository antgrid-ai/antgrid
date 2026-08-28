import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/composer_handoff.dart';
import 'package:antgrid/providers/session_mode.dart';
import 'package:antgrid/widgets/send_capture_to_agent.dart';

final _kBytes = Uint8List.fromList([1, 2, 3, 4]);

/// Pumps a throwaway widget purely to get a mounted [BuildContext] and the
/// container the helper routes through.
Future<({BuildContext context, ProviderContainer container})> _harness(
  WidgetTester tester, {
  required String? mode,
}) async {
  late BuildContext captured;
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [activeSessionModeProvider.overrideWithValue(mode)],
      child: MaterialApp(
        // A real Scaffold: the terminal branch reports failure through a
        // snack bar, which asserts without one to present into.
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              captured = context;
              container = ref.container;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  return (context: captured, container: container);
}

void main() {
  group('sendCaptureToAgent in chat mode', () {
    testWidgets('parks the capture for the composer instead of sending', (
      tester,
    ) async {
      final h = await _harness(tester, mode: 'chat');

      final sent = await sendCaptureToAgent(
        context: h.context,
        container: h.container,
        text: '[from preview: http://localhost:3000/]',
        imageBytes: _kBytes,
        fileName: 'shot.png',
      );

      // A chat agent takes files as attachments, so nothing is sent here —
      // the user still has to type and press send in the composer.
      expect(sent, isFalse);
      final handoff = h.container.read(composerHandoffProvider);
      expect(handoff, isNotNull);
      expect(handoff!.bytes, _kBytes);
      expect(handoff.fileName, 'shot.png');
      expect(handoff.mimeType, 'image/png');
      expect(handoff.text, '[from preview: http://localhost:3000/]');
    });

    testWidgets('a capture that failed still hands the text over', (
      tester,
    ) async {
      final h = await _harness(tester, mode: 'chat');

      await sendCaptureToAgent(
        context: h.context,
        container: h.container,
        text: 'the header is misaligned',
      );

      final handoff = h.container.read(composerHandoffProvider);
      expect(handoff, isNotNull);
      expect(handoff!.bytes, isNull);
      expect(handoff.fileName, isNull);
      expect(handoff.text, 'the header is misaligned');
    });
  });

  group('sendCaptureToAgent in terminal mode', () {
    testWidgets('never parks a composer handoff', (tester) async {
      final h = await _harness(tester, mode: 'terminal');

      // No project session is resolvable here, so this reports failure — the
      // point is that it took the TERMINAL branch and left the chat composer
      // alone rather than quietly stashing a capture nothing will collect.
      final sent = await sendCaptureToAgent(
        context: h.context,
        container: h.container,
        text: 'look at this',
        imageBytes: _kBytes,
        fileName: 'shot.png',
      );

      expect(sent, isFalse);
      expect(h.container.read(composerHandoffProvider), isNull);
    });

    testWidgets('an unknown mode is a terminal, not a chat', (tester) async {
      final h = await _harness(tester, mode: 'something-new');

      await sendCaptureToAgent(
        context: h.context,
        container: h.container,
        text: 'look at this',
      );

      expect(h.container.read(composerHandoffProvider), isNull);
    });

    testWidgets('no focused session is a terminal too', (tester) async {
      final h = await _harness(tester, mode: null);

      await sendCaptureToAgent(
        context: h.context,
        container: h.container,
        text: 'look at this',
      );

      expect(h.container.read(composerHandoffProvider), isNull);
    });
  });

  group('formatScreenshotAttachment', () {
    test('wraps the staged path as an attachment line', () {
      expect(
        formatScreenshotAttachment(r'C:\proj\.antgrid\uploads\shot.png'),
        r'Attached file: C:\proj\.antgrid\uploads\shot.png',
      );
    });
  });
}
