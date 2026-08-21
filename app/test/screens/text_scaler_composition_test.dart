import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/main.dart' show composedTextScalerFor;

/// Mirrors AbApp's builder wiring: an outer MediaQuery stands in for the OS
/// (textScaler 1.5), the inner copyWith applies [composedTextScalerFor] —
/// the exact expression main.dart's builder uses — and a probe Text reads
/// the effective scaler. `isMobilePlatform` is defaultTargetPlatform-based,
/// so the platform variant drives the mobile-vs-desktop branch.
Widget _harness({required double uiScale, double osScale = 1.5}) {
  return MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(osScale)),
    child: Builder(
      builder: (context) {
        final os = MediaQuery.of(context);
        return MediaQuery(
          data: os.copyWith(
            textScaler: composedTextScalerFor(
              uiScale: uiScale,
              osTextScaler: os.textScaler,
            ),
          ),
          child: const Directionality(
            textDirection: TextDirection.ltr,
            child: Text('probe'),
          ),
        );
      },
    ),
  );
}

double _probeScale(WidgetTester tester) =>
    MediaQuery.textScalerOf(tester.element(find.text('probe'))).scale(1.0);

void main() {
  testWidgets('composes uiScale with the OS scaler', (tester) async {
    await tester.pumpWidget(_harness(uiScale: 1.15));

    expect(_probeScale(tester), closeTo(1.15 * 1.5, 0.001));
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('clamps the composed product to the 2.0 ceiling', (tester) async {
    // 1.5 × 1.5 = 2.25 → clamped so extreme OS settings can't break the grid.
    await tester.pumpWidget(_harness(uiScale: 1.5));

    expect(_probeScale(tester), 2.0);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('clamps the composed product to the 0.85 floor', (tester) async {
    // 0.85 × 0.5 = 0.425 → floored to keep text readable.
    await tester.pumpWidget(_harness(uiScale: 0.85, osScale: 0.5));

    expect(_probeScale(tester), 0.85);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('replaces the OS scaler outright with uiScale', (tester) async {
    await tester.pumpWidget(_harness(uiScale: 1.15));

    expect(_probeScale(tester), closeTo(1.15, 0.001));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
