import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/widgets/transcript/rows/turn_fold_row.dart';
import 'package:antgrid/widgets/transcript/rows/working_row.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

Finder _findAbIcon(String glyph) =>
    find.byWidgetPredicate((w) => w is AbIcon && w.icon == glyph);

void main() {
  group('TurnFoldRow', () {
    testWidgets('shows Worked for 2m 35s when duration set', (tester) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 3,
        hasError: false,
        cancelled: false,
        duration: const Duration(minutes: 2, seconds: 35),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('Worked for 2m 35s'), findsOneWidget);
    });

    testWidgets('shows Worked for 1h 5m when duration is over an hour', (
      tester,
    ) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 3,
        hasError: false,
        cancelled: false,
        duration: const Duration(hours: 1, minutes: 5),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('Worked for 1h 5m'), findsOneWidget);
    });

    testWidgets('shows Worked for 2h 0m when minutes component is zero', (
      tester,
    ) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 3,
        hasError: false,
        cancelled: false,
        duration: const Duration(hours: 2, minutes: 0),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('Worked for 2h 0m'), findsOneWidget);
    });

    testWidgets('shows Worked for 45s when duration is under a minute', (
      tester,
    ) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 3,
        hasError: false,
        cancelled: false,
        duration: const Duration(seconds: 45),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('Worked for 45s'), findsOneWidget);
    });

    testWidgets('shows plain Worked when duration is null', (tester) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 3,
        hasError: false,
        cancelled: false,
        duration: null,
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('Worked'), findsOneWidget);
    });

    testWidgets('shows cancelled suffix when cancelled', (tester) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 3,
        hasError: false,
        cancelled: true,
        duration: const Duration(minutes: 2, seconds: 35),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('Worked for 2m 35s · cancelled'), findsOneWidget);
    });

    testWidgets('shows right-aligned hidden count', (tester) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 12,
        hasError: false,
        cancelled: false,
        duration: const Duration(minutes: 1),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(find.text('12 hidden'), findsOneWidget);
    });

    testWidgets('shows error glyph when hasError', (tester) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 1,
        hasError: true,
        cancelled: false,
        duration: const Duration(seconds: 5),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(_findAbIcon(AbIcons.error), findsOneWidget);
    });

    testWidgets('does not show error glyph when hasError is false', (
      tester,
    ) async {
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 1,
        hasError: false,
        cancelled: false,
        duration: const Duration(seconds: 5),
      );
      await _pump(
        tester,
        TurnFoldRow(data: data, expanded: false, onToggle: () {}),
      );

      expect(_findAbIcon(AbIcons.error), findsNothing);
    });

    testWidgets('onToggle fires on tap', (tester) async {
      var toggled = false;
      final data = TurnFoldRowData(
        turnId: 't1',
        hiddenCount: 1,
        hasError: false,
        cancelled: false,
        duration: const Duration(seconds: 5),
      );
      await _pump(
        tester,
        TurnFoldRow(
          data: data,
          expanded: false,
          onToggle: () => toggled = true,
        ),
      );

      await tester.tap(find.byType(TurnFoldRow));
      await tester.pump();

      expect(toggled, isTrue);
    });
  });

  group('WorkingRow', () {
    testWidgets(
      'shows Working for text and a Stop affordance that fires onStop',
      (tester) async {
        var stopped = false;
        final data = WorkingRowData(
          turnId: 't1',
          startedAt: DateTime.now(),
          waitingOnUser: false,
        );
        await _pump(
          tester,
          WorkingRow(data: data, onStop: () => stopped = true),
        );

        expect(find.textContaining('Working for'), findsOneWidget);

        await tester.tap(find.text('Stop'));
        await tester.pump();

        expect(stopped, isTrue);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'shows Waiting for you instead of Working for when waitingOnUser',
      (tester) async {
        final data = WorkingRowData(
          turnId: 't1',
          startedAt: DateTime.now(),
          waitingOnUser: true,
        );
        await _pump(tester, WorkingRow(data: data, onStop: () {}));

        expect(find.text('Waiting for you'), findsOneWidget);
        expect(find.textContaining('Working for'), findsNothing);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('timer text advances after 2 seconds', (tester) async {
      final data = WorkingRowData(
        turnId: 't1',
        startedAt: DateTime.now(),
        waitingOnUser: false,
      );
      await _pump(tester, WorkingRow(data: data, onStop: () {}));

      final before = tester
          .widget<Text>(find.textContaining('Working for'))
          .data;

      await tester.pump(const Duration(seconds: 2));

      final after = tester
          .widget<Text>(find.textContaining('Working for'))
          .data;

      expect(after, isNot(equals(before)));

      await tester.pumpWidget(const SizedBox());
    });
  });
}
