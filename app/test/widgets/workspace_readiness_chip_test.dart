// WorkspaceReadinessChip is a pure function of checkoutReadinessProvider, so
// every case here overrides that provider directly rather than driving its
// upstream dependencies (selectedTargetProvider, supervisorStatusProvider,
// projectSessionProvider, terminalStateProvider) through a fake transport.

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/ab_status_tone.dart';
import 'package:antgrid/widgets/carbon_status_dot.dart';
import 'package:antgrid/project/checkout_readiness.dart';
import 'package:antgrid/providers/checkout_readiness.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart';
import 'package:antgrid/widgets/workspace_readiness_chip.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(find.byType(CarbonTag), findsNothing);
  });

  for (final readiness in _nonReady) {
    final (tone, label) = readinessDisplayInfo(readiness);

    testWidgets('$readiness renders "$label" as a tag with a ${tone.name} dot', (
      tester,
    ) async {
      await _pump(tester, readiness);

      final tag = tester.widget<CarbonTag>(find.byType(CarbonTag));
      expect(tag.label, label);
      expect(find.text(label), findsOneWidget);

      final dot = tester.widget<CarbonStatusDot>(
        find.byKey(const Key('readiness-dot')),
      );
      final c = CarbonTheme.of(tester.element(find.byType(CarbonTag))).colors;
      expect(dot.color, switch (tone) {
        AbStatusTone.danger => c.supportError,
        AbStatusTone.warning => c.supportWarning,
        _ => c.iconDisabled,
      });
    });
  }

  testWidgets('the tag draws its status dot inside its own bounds', (
    tester,
  ) async {
    await _pump(tester, CheckoutReadiness.stalled);

    final tag = tester.getRect(find.byType(CarbonTag));
    final dot = tester.getRect(find.byKey(const Key('readiness-dot')));
    expect(tag.contains(dot.center), isTrue);
    expect(dot.right, lessThan(tester.getTopLeft(find.text("Couldn't reach agent")).dx));
  });
}
