// The image sits on the phone's second page, so every gesture over it races
// the PageView's horizontal drag, which accepts at the device's touch slop.
// Pinches and zoomed pans must win that race; a one-finger swipe at fit size
// must lose it.
import 'dart:ui' show GestureSettings;

import 'package:antgrid/widgets/zoomable_image.dart';
import 'package:flutter/gestures.dart' show kDoubleTapMinTime;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PageController pages;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    // Android's ViewConfiguration slop, not the framework's 18px default.
    tester.view.gestureSettings = const GestureSettings(physicalTouchSlop: 8);
    addTearDown(tester.view.reset);
    pages = PageController(initialPage: 1);
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PageView(
          controller: pages,
          children: const [
            ColoredBox(color: Colors.black),
            ZoomableImage(child: ColoredBox(color: Colors.white)),
          ],
        ),
      ),
    );
  }

  ZoomableImageState zoom(WidgetTester tester) =>
      tester.state<ZoomableImageState>(find.byType(ZoomableImage));

  double page() => pages.page!;

  Future<void> pinchOut(
    WidgetTester tester, {
    Offset firstFingerDrift = Offset.zero,
  }) async {
    const center = Offset(200, 400);
    final a = await tester.startGesture(center - const Offset(20, 0));
    if (firstFingerDrift != Offset.zero) {
      await a.moveBy(firstFingerDrift);
      await tester.pump();
    }
    final b = await tester.startGesture(center + const Offset(20, 0));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
  }

  Future<void> doubleTap(WidgetTester tester) async {
    const at = Offset(200, 400);
    await tester.tapAt(at);
    await tester.pump(kDoubleTapMinTime);
    await tester.tapAt(at);
    await tester.pumpAndSettle();
  }

  testWidgets('a horizontal pinch zooms instead of turning the page', (
    tester,
  ) async {
    await pump(tester);

    await pinchOut(tester);

    expect(page(), 1);
    expect(zoom(tester).scale, greaterThan(2));
  });

  testWidgets('a pinch still zooms when the first finger drifted sideways', (
    tester,
  ) async {
    await pump(tester);

    // Under the page's slop: the PageView has not accepted yet.
    await pinchOut(tester, firstFingerDrift: const Offset(5, 0));

    expect(page(), 1);
    expect(zoom(tester).scale, greaterThan(2));
  });

  testWidgets('a one-finger swipe at fit size turns the page', (tester) async {
    await pump(tester);

    await tester.timedDrag(
      find.byType(ZoomableImage),
      const Offset(300, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(page(), 0);
  });

  testWidgets('once zoomed, a one-finger swipe pans the image', (tester) async {
    await pump(tester);
    await doubleTap(tester);
    expect(zoom(tester).isZoomed, isTrue);

    await tester.timedDrag(
      find.byType(ZoomableImage),
      const Offset(150, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();

    expect(page(), 1);
    expect(zoom(tester).isZoomed, isTrue);
  });

  testWidgets('double-tap zooms in, and again fits back', (tester) async {
    await pump(tester);

    await doubleTap(tester);
    expect(zoom(tester).scale, closeTo(ZoomableImage.doubleTapScale, 0.01));

    await doubleTap(tester);
    expect(zoom(tester).scale, closeTo(1, 0.01));
  });

  testWidgets('pinching in stops at fit size', (tester) async {
    await pump(tester);
    await doubleTap(tester);

    const center = Offset(200, 400);
    final a = await tester.startGesture(center - const Offset(150, 0));
    final b = await tester.startGesture(center + const Offset(150, 0));
    await tester.pump();
    for (var i = 0; i < 14; i++) {
      await a.moveBy(const Offset(10, 0));
      await b.moveBy(const Offset(-10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();

    expect(zoom(tester).scale, closeTo(1, 0.01));
    expect(page(), 1);
  });
}
