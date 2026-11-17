import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/design/widgets/pulsing_opacity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _PaintCounter extends CustomPainter {
  int paints = 0;

  @override
  void paint(Canvas canvas, Size size) => paints++;

  @override
  bool shouldRepaint(_PaintCounter oldDelegate) => false;
}

Widget _host(List<Widget> children) => MediaQuery(
  data: const MediaQueryData(),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Theme(
      data: buildAbTheme(kDefaultPalette),
      child: Row(children: children),
    ),
  ),
);

void main() {
  for (final loader in <Widget>[const AbLoading(), const AbLoadingDot()]) {
    testWidgets('${loader.runtimeType} bounds frames and isolates paint', (
      tester,
    ) async {
      var frames = 0;
      tester.binding.addPersistentFrameCallback((_) => frames++);
      final sibling = _PaintCounter();
      await tester.pumpWidget(
        _host([
          SizedBox(width: 200, height: 60, child: loader),
          CustomPaint(painter: sibling, size: const Size(200, 60)),
        ]),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final paints = sibling.paints;
      frames = 0;
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(frames, inInclusiveRange(1, 10));
      expect(sibling.paints, paints);
    });
  }

  testWidgets('the loading dot changes painted size without changing layout', (
    tester,
  ) async {
    await tester.pumpWidget(_host([const AbLoadingDot()]));
    final dot = find.descendant(
      of: find.byType(AbLoadingDot),
      matching: find.byType(DecoratedBox),
    );
    final initialSize = tester.getSize(dot);
    final initialPaintedSize = tester.getRect(dot).size;
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getSize(dot), initialSize);
    expect(tester.getRect(dot).size, isNot(initialPaintedSize));
  });

  testWidgets('staggered loaders and status pulses share one frame budget', (
    tester,
  ) async {
    var frames = 0;
    tester.binding.addPersistentFrameCallback((_) => frames++);
    final existing = <Widget>[
      const SizedBox(width: 100, height: 60, child: AbLoading()),
      const PulsingOpacity(child: SizedBox(width: 8, height: 8)),
    ];
    await tester.pumpWidget(_host(existing));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(_host([...existing, const AbLoadingDot()]));
    frames = 0;
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(frames, inInclusiveRange(1, 10));
  });

  testWidgets('loaders retain their different pulse periods and ranges', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        const SizedBox(width: 100, height: 60, child: AbLoading()),
        const AbLoadingDot(),
      ]),
    );
    final block = find.descendant(
      of: find.byType(AbLoading),
      matching: find.byType(DecoratedBox),
    );
    final dot = find.descendant(
      of: find.byType(AbLoadingDot),
      matching: find.byType(DecoratedBox),
    );
    double alpha() =>
        (tester.widget<DecoratedBox>(block).decoration as BoxDecoration)
            .color!
            .a;
    expect(alpha(), closeTo(0.2, 0.001));
    expect(tester.getRect(dot).width, closeTo(12 * 0.4, 0.001));
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.getRect(dot).width, closeTo(12, 0.001));
    expect(alpha(), lessThan(1));
    await tester.pump(const Duration(milliseconds: 200));
    expect(alpha(), closeTo(1, 0.001));
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.getRect(dot).width, closeTo(12 * 0.4, 0.001));
    await tester.pump(const Duration(milliseconds: 400));
    expect(alpha(), closeTo(0.2, 0.001));
  });
}
