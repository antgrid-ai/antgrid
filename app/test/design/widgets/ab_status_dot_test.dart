// The pulse used to be a plain 0.45→1.0 opacity fade, and how much of a blink
// that produces depends entirely on how bright the dot is: it swung a near-white
// accent from brilliant to mid-gray, and barely moved a mid-tone one. Same
// animation, visibly blinking on one theme preset and static-looking on another.
// Scale is what makes it palette-independent, so these assert BOTH move.
import 'package:antgrid/design/ab_status_tone.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The live opacity/scale the pulse is currently painting.
({double opacity, double scale}) _frame(WidgetTester tester) {
  final opacity = tester
      .widgetList<Opacity>(
        find.descendant(
          of: find.byType(AbStatusDot),
          matching: find.byType(Opacity),
        ),
      )
      .first
      .opacity;
  final transform = tester
      .widgetList<Transform>(
        find.descendant(
          of: find.byType(AbStatusDot),
          matching: find.byType(Transform),
        ),
      )
      .first
      .transform;
  // Uniform scale, so any diagonal entry is the factor.
  return (opacity: opacity, scale: transform.storage[0]);
}

Future<void> _pump(WidgetTester tester, {bool reduceMotion = false}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: AbStatusDot(tone: AbStatusTone.info, pulse: true),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a pulsing dot dims AND shrinks', (tester) async {
    await _pump(tester);
    // Quarter of the 900ms cycle in, both are mid-swing.
    await tester.pump(const Duration(milliseconds: 225));
    final mid = _frame(tester);
    expect(mid.opacity, lessThan(1.0));
    expect(mid.scale, lessThan(1.0));

    // Opacity alone is what made this palette-dependent; the size change is the
    // half that reads at any hue, so it has to be a real one.
    await tester.pump(const Duration(milliseconds: 225));
    final end = _frame(tester);
    expect(end.scale, isNot(closeTo(mid.scale, 0.001)));
  });

  testWidgets('the pulse never fades or shrinks the dot away', (tester) async {
    // A dot that vanishes reads as "gone", not "working" — the floors are what
    // keep it legible at the bottom of the cycle.
    await _pump(tester);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 75));
      final f = _frame(tester);
      expect(f.opacity, greaterThanOrEqualTo(0.3));
      expect(f.scale, greaterThanOrEqualTo(0.65));
    }
  });

  testWidgets('reduce motion pins the dot at full', (tester) async {
    await _pump(tester, reduceMotion: true);
    await tester.pump(const Duration(milliseconds: 450));
    final f = _frame(tester);
    expect(f.opacity, 1.0);
    expect(f.scale, 1.0);
  });

  testWidgets('a still dot carries no animation layers at all', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: AbStatusDot(tone: AbStatusTone.unread)),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(AbStatusDot),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
  });
}
