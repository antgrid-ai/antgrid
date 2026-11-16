import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/carbon_empty_state.dart';
import 'package:antgrid/widgets/preview_empty_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host() => const MaterialApp(
  home: Scaffold(body: AbCarbonScope(child: PreviewEmptyState())),
);

void main() {
  group('PreviewEmptyState', () {
    testWidgets('renders icon and title text', (tester) async {
      await tester.pumpWidget(_host());

      expect(find.byType(CarbonEmptyState), findsOneWidget);
      expect(find.text('Open a preview'), findsOneWidget);
    });

    testWidgets('renders subtitle text', (tester) async {
      await tester.pumpWidget(_host());

      expect(
        find.text('Enter a dev server port above\nto preview it here'),
        findsOneWidget,
      );
    });
  });
}
