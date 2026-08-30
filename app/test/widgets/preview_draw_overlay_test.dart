import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/preview_draw_overlay.dart';

// A valid 8x8 opaque PNG — small enough to inline, real enough to decode.
final Uint8List _kTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGMQkdPAihiGlgQA'
  'xkAWgVkQE9kAAAAASUVORK5CYII=',
);

/// Polls [condition] in real time via [WidgetTester.runAsync] — image decode
/// and `Picture.toImage` are real engine work off the fake test clock, so
/// plain `pump()`/`pumpAndSettle()` never observes them finishing.
Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxAttempts = 60,
}) async {
  for (var i = 0; i < maxAttempts; i++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  // Let the final `expect` in the caller report the real failure instead of
  // this helper doing it blind.
}

/// What the overlay reported back through its callbacks.
class _Reported {
  bool closed = false;
  Uint8List? sent;
  int captures = 0;
}

Future<_Reported> _pumpOverlay(
  WidgetTester tester, {
  Uint8List? screenshot,
}) async {
  final reported = _Reported();
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 600,
            child: PreviewDrawOverlay(
              captureScreenshot: () async {
                reported.captures++;
                return screenshot ?? _kTinyPng;
              },
              onClose: () => reported.closed = true,
              onSend: (bytes) => reported.sent = bytes,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return reported;
}

Finder get _canvas => find.byKey(const ValueKey('preview-draw-canvas'));

Future<void> _drawStroke(WidgetTester tester) async {
  await tester.drag(_canvas, const Offset(40, 40));
  await tester.pumpAndSettle();
}

void main() {
  group('PreviewDrawOverlay', () {
    testWidgets('arming captures nothing — the page is only read on send', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);

      // The whole point of drawing on the live page: no screenshot is taken
      // when the overlay comes up, so the preview never freezes or flickers.
      expect(reported.captures, 0);
      expect(find.text('Send'), findsOneWidget);
      expect(find.bySemanticsLabel('Close'), findsOneWidget);
    });

    testWidgets('closing with nothing drawn does not ask first', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Discard drawing?'), findsNothing);
      expect(reported.closed, isTrue);
    });

    testWidgets('closing with marks asks, and keeps them on decline', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);
      await _drawStroke(tester);

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard drawing?'), findsOneWidget);

      await tester.tap(find.text('Keep drawing'));
      await tester.pumpAndSettle();
      expect(reported.closed, isFalse);

      // The mark that prompted the question survived, so closing asks again.
      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard drawing?'), findsOneWidget);
    });

    testWidgets('confirming the discard closes', (tester) async {
      final reported = await _pumpOverlay(tester);
      await _drawStroke(tester);

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(reported.closed, isTrue);
      expect(reported.sent, isNull);
    });

    testWidgets('sending captures once and returns a flattened PNG', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);
      await _drawStroke(tester);

      await tester.tap(find.text('Send'));
      await tester.pump();
      await _waitUntil(tester, () => reported.sent != null);
      await tester.pumpAndSettle();

      expect(reported.captures, 1);
      expect(reported.sent, isNotNull);
      // PNG magic bytes, and not simply the input echoed back — the marks
      // were composited onto it.
      expect(reported.sent!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
      expect(reported.sent, isNot(equals(_kTinyPng)));
    });

    testWidgets('a shape tool that never dragged leaves no mark behind', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);

      await tester.tap(find.bySemanticsLabel('Rectangle'));
      await tester.pumpAndSettle();
      // A tap, not a drag: a zero-sized rectangle is invisible, so it must
      // not count as unsaved work at close time.
      await tester.tapAt(tester.getCenter(_canvas));
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Discard drawing?'), findsNothing);
      expect(reported.closed, isTrue);
    });

    testWidgets('the text tool places a note where it was tapped', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);

      await tester.tap(find.bySemanticsLabel('Text'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(_canvas));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'broken here');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // Editor gone, and the note it committed counts as work to lose.
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard drawing?'), findsOneWidget);
      expect(reported.closed, isFalse);
    });

    testWidgets('an empty note is dropped rather than left as a mark', (
      tester,
    ) async {
      final reported = await _pumpOverlay(tester);

      await tester.tap(find.bySemanticsLabel('Text'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(_canvas));
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Discard drawing?'), findsNothing);
      expect(reported.closed, isTrue);
    });
  });

  group('compositePreviewMarks', () {
    test('returns the screenshot untouched when nothing was drawn', () async {
      final out = await compositePreviewMarks(
        screenshot: _kTinyPng,
        marks: const [],
        overlaySize: const Size(400, 600),
      );
      expect(out, same(_kTinyPng));
    });

    test('reports failure rather than throwing on undecodable bytes', () async {
      final out = await compositePreviewMarks(
        screenshot: Uint8List.fromList([1, 2, 3]),
        marks: [
          PreviewDrawMark(
            tool: PreviewDrawTool.pen,
            color: const Color(0xFFFF0000),
            points: [Offset.zero, const Offset(10, 10)],
          ),
        ],
        overlaySize: const Size(400, 600),
      );
      expect(out, isNull);
    });
  });
}
