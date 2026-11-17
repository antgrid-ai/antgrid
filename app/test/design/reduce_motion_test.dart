import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';

Widget _harness(Widget loader, {required bool disableAnimations}) {
  return MediaQuery(
    data: MediaQueryData(disableAnimations: disableAnimations),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(data: buildAbTheme(kDefaultPalette), child: loader),
    ),
  );
}

({double alpha, Size size}) _appearance(WidgetTester tester, Type type) {
  final glyph = find.descendant(
    of: find.byType(type),
    matching: find.byType(DecoratedBox),
  );
  final decoration =
      tester.widget<DecoratedBox>(glyph).decoration as BoxDecoration;
  return (alpha: decoration.color!.a, size: tester.getRect(glyph).size);
}

void main() {
  for (final loader in <Widget>[const AbLoading(), const AbLoadingDot()]) {
    final type = loader.runtimeType;
    testWidgets('$type pulses when animations are enabled', (tester) async {
      await tester.pumpWidget(_harness(loader, disableAnimations: false));
      final initial = _appearance(tester, type);
      await tester.pump(const Duration(milliseconds: 400));
      expect(_appearance(tester, type), isNot(initial));
    });

    testWidgets('$type holds its resting appearance under reduce motion', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(loader, disableAnimations: true));
      final initial = _appearance(tester, type);
      if (loader is AbLoading) {
        expect(initial.alpha, closeTo(0.6, 0.001));
      } else {
        expect(initial.size.width, closeTo(12 * 0.7, 0.001));
      }
      await tester.pump(const Duration(seconds: 2));
      expect(_appearance(tester, type), initial);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('$type stops and resumes on a live reduce-motion flip', (
      tester,
    ) async {
      await tester.pumpWidget(_harness(loader, disableAnimations: false));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(_harness(loader, disableAnimations: true));
      final resting = _appearance(tester, type);
      await tester.pump(const Duration(seconds: 2));
      expect(_appearance(tester, type), resting);
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.pumpWidget(_harness(loader, disableAnimations: false));
      final resumed = _appearance(tester, type);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_appearance(tester, type), isNot(resumed));
    });
  }
}
