import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/pulsing_opacity.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/rows/plan_checklist.dart';
import 'package:antgrid/widgets/transcript/selection/transcript_selection_scope.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TranscriptSelectionScope(
          controller: TranscriptSelectionController(),
          child: SelectionArea(child: child),
        ),
      ),
    ),
  );
}

void main() {
  group('PlanChecklist', () {
    testWidgets('shows Plan · done/total header for one completed of three', (
      tester,
    ) async {
      final data = PlanRowData(
        const AgentItem(
          itemId: 'i1',
          kind: 'plan',
          entries: [
            PlanEntry(text: 'step one', status: 'completed'),
            PlanEntry(text: 'step two', status: 'running'),
            PlanEntry(text: 'step three', status: 'pending'),
          ],
        ),
      );
      await _pump(tester, PlanChecklist(data: data, rowIndex: 0));

      expect(find.text('Plan · 1/3'), findsOneWidget);
    });

    testWidgets('a completed entry renders its text with lineThrough', (
      tester,
    ) async {
      final data = PlanRowData(
        const AgentItem(
          itemId: 'i1',
          kind: 'plan',
          entries: [PlanEntry(text: 'step one', status: 'completed')],
        ),
      );
      await _pump(tester, PlanChecklist(data: data, rowIndex: 0));

      final text = tester.widget<Text>(find.text('step one'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('a running entry is wrapped in PulsingOpacity', (tester) async {
      final data = PlanRowData(
        const AgentItem(
          itemId: 'i1',
          kind: 'plan',
          entries: [PlanEntry(text: 'step two', status: 'running')],
        ),
      );
      await _pump(tester, PlanChecklist(data: data, rowIndex: 0));

      expect(find.byType(PulsingOpacity), findsOneWidget);
    });

    testWidgets('an entry with an unknown status renders as pending', (
      tester,
    ) async {
      final data = PlanRowData(
        const AgentItem(
          itemId: 'i1',
          kind: 'plan',
          entries: [PlanEntry(text: 'step mystery', status: 'weird')],
        ),
      );
      await _pump(tester, PlanChecklist(data: data, rowIndex: 0));

      expect(find.text('○'), findsOneWidget);
      expect(find.byType(PulsingOpacity), findsNothing);
      final text = tester.widget<Text>(find.text('step mystery'));
      expect(text.style?.decoration, isNot(TextDecoration.lineThrough));
    });

    testWidgets('empty/null entries render only the Plan · 0/0 header', (
      tester,
    ) async {
      final data = PlanRowData(const AgentItem(itemId: 'i1', kind: 'plan'));
      await _pump(tester, PlanChecklist(data: data, rowIndex: 0));

      expect(find.text('Plan · 0/0'), findsOneWidget);
      expect(find.text('●'), findsNothing);
      expect(find.text('◐'), findsNothing);
      expect(find.text('○'), findsNothing);
    });
  });
}
