import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/drawer/drawer_chrome_row.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(
  WidgetTester tester, {
  VoidCallback? onPressed,
  Widget? trailing,
  FocusNode? focusNode,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: AbCarbonScope(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: DrawerChromeRow(
            icon: CarbonIcons.user,
            label: 'dev@example.com',
            trailing: trailing,
            onPressed: onPressed,
            focusNode: focusNode,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('shows its label and trailing, and a tap presses once', (
    tester,
  ) async {
    var presses = 0;
    await _pump(
      tester,
      onPressed: () => presses++,
      trailing: const Text('Pro'),
    );
    expect(find.text('dev@example.com'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
    await tester.tap(find.byType(DrawerChromeRow));
    expect(presses, 1);
  });

  testWidgets('a null onPressed leaves the row inert and unfocusable', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await _pump(tester, focusNode: node);
    node.requestFocus();
    await tester.pump();
    expect(node.hasFocus, isFalse);
  });

  testWidgets('the row is at least 40 tall on a pointer platform', (
    tester,
  ) async {
    await _pump(tester, onPressed: () {});
    expect(
      tester.getSize(find.byType(DrawerChromeRow)).height,
      greaterThanOrEqualTo(CarbonSizes.md),
    );
  }, variant: TargetPlatformVariant.desktop());

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('the row is a full touch target on a phone', (tester) async {
      await _pump(tester, onPressed: () {});
      final theme = CarbonTheme.of(
        tester.element(find.byType(DrawerChromeRow)),
      );
      expect(tester.getSize(find.byType(DrawerChromeRow)).height,
          greaterThanOrEqualTo(theme.minTarget));
    }, variant: TargetPlatformVariant.only(platform));
  }
}
