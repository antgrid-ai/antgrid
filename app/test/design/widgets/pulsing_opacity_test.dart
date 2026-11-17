import 'package:antgrid/design/widgets/pulsing_opacity.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) {
    paints++;
  }

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

void main() {
  Widget host({bool reduceMotion = false, bool enabled = true, int count = 1}) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: TickerMode(
        enabled: enabled,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Row(
            children: List.generate(
              count,
              (index) => PulsingOpacity(
                key: ValueKey(index),
                minScale: 0.7,
                child: const SizedBox(width: 8, height: 8),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double opacity(WidgetTester tester) =>
      tester.widgetList<Opacity>(find.byType(Opacity)).first.opacity;

  testWidgets('status pulses request at most ten frames per second', (
    tester,
  ) async {
    var requestedFrames = 0;
    tester.binding.addPersistentFrameCallback((_) => requestedFrames++);
    await tester.pumpWidget(host());
    requestedFrames = 0;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(requestedFrames, greaterThan(0));
    expect(requestedFrames, lessThanOrEqualTo(10));
    expect(opacity(tester), greaterThan(0.45));
  });

  testWidgets('newly mounted pulses share the existing pulse phase', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpWidget(host(count: 2));
    final values = tester.widgetList<Opacity>(find.byType(Opacity));
    expect(values.last.opacity, values.first.opacity);
  });

  testWidgets('reduce motion and TickerMode stop and resume the pulse', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), lessThan(1));
    await tester.pumpWidget(host(reduceMotion: true));
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(host(enabled: false));
    await tester.pump(const Duration(seconds: 2));
    expect(opacity(tester), 1);
    expect(tester.binding.hasScheduledFrame, isFalse);

    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 400));
    expect(opacity(tester), lessThan(1));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('hidden app stops the shared clock until it is visible', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(host());
    await tester.pump(const Duration(milliseconds: 400));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    final before = opacity(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(opacity(tester), isNot(before));
  });

  for (final minScale in <double?>[null, 0.7]) {
    testWidgets('pulse ($minScale) does not repaint surrounding content', (
      tester,
    ) async {
      final sibling = _PaintCounter();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Row(
              children: [
                PulsingOpacity(
                  minScale: minScale,
                  child: const SizedBox(width: 8, height: 8),
                ),
                CustomPaint(painter: sibling, size: const Size(200, 200)),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final initialPaints = sibling.paints;
      expect(initialPaints, greaterThan(0));
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(sibling.paints, initialPaints);
    });
  }
}
