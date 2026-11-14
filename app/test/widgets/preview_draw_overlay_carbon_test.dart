// What the Carbon draw bar owes beyond the behaviour preview_draw_overlay_test
// pins: no Ab widgets under its scope in any state, both densities and both
// brightnesses, a palette that reaches the marks, and Escape closing only the
// popup.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/preview_draw_overlay.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  Size size = const Size(400, 600),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: PreviewDrawOverlay(
            captureScreenshot: () async => null,
            onClose: () {},
            onSend: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _canvas => find.byKey(const ValueKey('preview-draw-canvas'));

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('no Ab widgets in the bar, the palette or the note editor '
        '(${brightness.name})', (tester) async {
      await _pump(tester, brightness: brightness);
      expect(abWidgetsInScope(tester), isEmpty);
      expect(find.byType(AbCarbonScope), findsOneWidget);

      await tester.ensureVisible(find.bySemanticsLabel('Pen color'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Pen color'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Green'), findsWidgets);
      expect(abWidgetsInScope(tester), isEmpty);
      await tester.tap(find.bySemanticsLabel('Green'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Green'), findsNothing);

      await tester.ensureVisible(find.bySemanticsLabel('Note'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Note'));
      await tester.pumpAndSettle();
      await tester.tapAt(tester.getCenter(_canvas));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(abWidgetsInScope(tester), isEmpty);
    });
  }

  testWidgets('no Ab widgets while the discard modal is open', (tester) async {
    await _pump(tester);
    await tester.drag(_canvas, const Offset(40, 40));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard drawing?'), findsOneWidget);
    expect(find.byType(CarbonModal), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  const everyControl = [
    'Freehand',
    'Line',
    'Rectangle',
    'Ellipse',
    'Note',
    'Pen color',
    'Undo',
    'Clear',
    'Close',
    'Send',
  ];

  Rect rectOf(WidgetTester tester, String label) =>
      tester.getRect(find.bySemanticsLabel(label).first);

  testWidgets('a phone-width bar stacks the actions under the tools with '
      'every control on screen', (tester) async {
    await _pump(tester, size: const Size(390, 700));
    final screen = Offset.zero & tester.view.physicalSize;
    for (final label in everyControl) {
      final rect = rectOf(tester, label);
      expect(
        screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
        isTrue,
        reason: '$label at $rect is off screen',
      );
    }
    // Inside the screen is not enough: a clipped cell still lies within it.
    final viewport = tester.getRect(find.byType(Scrollable).last);
    for (final label in everyControl.take(6)) {
      final rect = rectOf(tester, label);
      expect(
        rect.left >= viewport.left - 0.5 && rect.right <= viewport.right + 0.5,
        isTrue,
        reason: '$label at $rect is clipped by the tool scroller $viewport',
      );
    }
    expect(
      tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .maxScrollExtent,
      0,
      reason: 'no tool may sit behind a swipe',
    );
    expect(
      rectOf(tester, 'Undo').top,
      greaterThanOrEqualTo(rectOf(tester, 'Freehand').bottom),
    );
    expect(
      rectOf(tester, 'Send').center.dy,
      moreOrLessEquals(rectOf(tester, 'Undo').center.dy, epsilon: 1),
    );
  });

  testWidgets('a bar wide enough for both groups keeps one row', (
    tester,
  ) async {
    await _pump(tester, size: const Size(900, 600));
    final row = rectOf(tester, 'Freehand').center.dy;
    for (final label in everyControl) {
      expect(
        rectOf(tester, label).center.dy,
        moreOrLessEquals(row, epsilon: 1),
        reason: label,
      );
    }
    expect(
      rectOf(tester, 'Undo').left,
      greaterThan(rectOf(tester, 'Pen color').right),
    );
  });

  testWidgets('the bar fits a narrow touch panel at double text scale', (
    tester,
  ) async {
    await _pump(tester, size: const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    expect(abWidgetsInScope(tester), isEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Escape closes the colour popup and leaves the overlay open', (
    tester,
  ) async {
    await _pump(tester);
    await tester.ensureVisible(find.bySemanticsLabel('Pen color'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Pen color'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Blue'), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Blue'), findsNothing);
    expect(find.byType(PreviewDrawOverlay), findsOneWidget);
    expect(find.text('Discard drawing?'), findsNothing);
  });
}
