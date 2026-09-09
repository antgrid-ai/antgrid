// WorkspaceReadinessChip is a pure function of checkoutReadinessProvider, so
// every case here overrides that provider directly rather than driving its
// upstream dependencies (selectedTargetProvider, supervisorStatusProvider,
// projectSessionProvider, terminalStateProvider) through a fake transport.

import 'dart:math' as math;

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/project/checkout_readiness.dart';
import 'package:antgrid/providers/checkout_readiness.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart';
import 'package:antgrid/widgets/workspace_readiness_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// WCAG 2.x relative luminance / contrast, mirrored from
// app/test/design/palette_contrast_test.dart (private there, so duplicated
// rather than imported) — the same method the rest of the design system is
// held to, not a bespoke one for this widget.
double _relativeLuminance(Color c) {
  double linearize(double ch) =>
      ch <= 0.03928 ? ch / 12.92 : math.pow((ch + 0.055) / 1.055, 2.4) as double;
  return 0.2126 * linearize(c.r) +
      0.7152 * linearize(c.g) +
      0.0722 * linearize(c.b);
}

double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a) + 0.05;
  final lb = _relativeLuminance(b) + 0.05;
  return la > lb ? la / lb : lb / la;
}

Future<void> _pump(WidgetTester tester, CheckoutReadiness readiness) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [checkoutReadinessProvider.overrideWithValue(readiness)],
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: const Scaffold(body: Center(child: WorkspaceReadinessChip())),
      ),
    ),
  );
}

const _nonReady = [
  CheckoutReadiness.cold,
  CheckoutReadiness.blocked,
  CheckoutReadiness.reachingMachine,
  CheckoutReadiness.openingSession,
  CheckoutReadiness.loadingScreen,
  CheckoutReadiness.stalled,
];

void main() {
  testWidgets('renders nothing at ready — an exception reporter, not a badge', (
    tester,
  ) async {
    await _pump(tester, CheckoutReadiness.ready);

    expect(find.byType(WorkspaceReadinessChip), findsOneWidget);
    expect(
      tester.getSize(find.byType(WorkspaceReadinessChip)),
      Size.zero,
    );
    expect(find.byType(AbStatusDot), findsNothing);
  });

  for (final readiness in _nonReady) {
    final (tone, label) = readinessDisplayInfo(readiness);

    testWidgets('$readiness renders "$label" at its ${tone.name} tone', (
      tester,
    ) async {
      await _pump(tester, readiness);

      expect(find.text(label), findsOneWidget);
      final dot = tester.widget<AbStatusDot>(find.byType(AbStatusDot));
      expect(dot.tone, tone);
    });

    testWidgets('$readiness label colour clears the body-text contrast floor', (
      tester,
    ) async {
      await _pump(tester, readiness);

      final text = tester.widget<Text>(find.text(label));
      final color = text.style!.color!;
      final ratio = _contrast(color, kDefaultPalette.bgSurface);
      expect(
        ratio,
        greaterThanOrEqualTo(4.5),
        reason:
            '$readiness label "$label" is ${ratio.toStringAsFixed(2)}:1 on '
            'bgSurface, below WCAG AA 4.5:1',
      );
    });
  }
}
