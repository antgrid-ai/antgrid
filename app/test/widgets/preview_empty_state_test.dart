import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/widgets/preview_empty_state.dart';

void main() {
  group('PreviewEmptyState', () {
    testWidgets('renders icon and title text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PreviewEmptyState())),
      );

      expect(find.byType(AbEmptyState), findsOneWidget);
      expect(find.text('Open a Preview'), findsOneWidget);
    });

    testWidgets('renders subtitle text', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PreviewEmptyState())),
      );

      expect(
        find.text('Enter a dev server port below\nto preview it here'),
        findsOneWidget,
      );
    });
  });
}
