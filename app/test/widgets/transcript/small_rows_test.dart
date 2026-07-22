import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/rows/compaction_divider.dart';
import 'package:antgrid/widgets/transcript/rows/error_banner.dart';
import 'package:antgrid/widgets/transcript/rows/prompt_marker_row.dart';
import 'package:antgrid/widgets/transcript/rows/subtask_row.dart';
import 'package:antgrid/widgets/transcript/rows/unknown_row.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('ErrorBanner', () {
    testWidgets('shows category chip and message', (tester) async {
      final data = ErrorRowData(
        turnId: 't1',
        error: const AgentError(
          category: 'network',
          message: 'connection lost',
          retryable: false,
        ),
      );
      await _pump(tester, ErrorBanner(data: data, onDismiss: () {}));

      expect(find.text('NETWORK'), findsOneWidget);
      expect(find.text('connection lost'), findsOneWidget);
    });

    testWidgets('shows retryable · retry in 30s when retryAfterMs is 30000', (
      tester,
    ) async {
      final data = ErrorRowData(
        turnId: 't1',
        error: const AgentError(
          category: 'network',
          message: 'connection lost',
          retryable: true,
          retryAfterMs: 30000,
        ),
      );
      await _pump(tester, ErrorBanner(data: data, onDismiss: () {}));

      expect(find.text('retryable · retry in 30s'), findsOneWidget);
    });

    testWidgets('shows just retryable when retryAfterMs is null', (
      tester,
    ) async {
      final data = ErrorRowData(
        turnId: 't1',
        error: const AgentError(
          category: 'network',
          message: 'connection lost',
          retryable: true,
        ),
      );
      await _pump(tester, ErrorBanner(data: data, onDismiss: () {}));

      expect(find.text('retryable'), findsOneWidget);
    });

    testWidgets('onDismiss fires when the close icon button is tapped', (
      tester,
    ) async {
      var dismissed = false;
      final data = ErrorRowData(
        turnId: 't1',
        error: const AgentError(
          category: 'network',
          message: 'connection lost',
          retryable: false,
        ),
      );
      await _pump(
        tester,
        ErrorBanner(data: data, onDismiss: () => dismissed = true),
      );

      await tester.tap(find.byType(GestureDetector).first);
      await tester.pump();

      expect(dismissed, isTrue);
    });
  });

  group('CompactionDivider', () {
    testWidgets('shows context compacted', (tester) async {
      final data = CompactionRowData(
        const AgentItem(itemId: 'i1', kind: 'compaction'),
      );
      await _pump(tester, CompactionDivider(data: data));

      expect(find.text('context compacted'), findsOneWidget);
    });
  });

  group('SubtaskRow', () {
    testWidgets('shows agent name and a status glyph', (tester) async {
      final data = SubtaskRowData(
        const AgentItem(
          itemId: 'i1',
          kind: 'subtask',
          agent: 'reviewer',
          status: 'completed',
        ),
      );
      await _pump(tester, SubtaskRow(data: data));

      expect(find.text('reviewer'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is AbIcon), findsWidgets);
    });
  });

  group('PromptMarkerRow', () {
    testWidgets('shows waiting for approval when isPermission', (tester) async {
      const data = PromptMarkerRowData(id: 'p1', isPermission: true);
      await _pump(tester, const PromptMarkerRow(data: data));

      expect(find.text('⧖ waiting for approval'), findsOneWidget);
    });

    testWidgets('shows waiting for an answer when not isPermission', (
      tester,
    ) async {
      const data = PromptMarkerRowData(id: 'q1', isPermission: false);
      await _pump(tester, const PromptMarkerRow(data: data));

      expect(find.text('⧖ waiting for an answer'), findsOneWidget);
    });
  });

  group('UnknownRow', () {
    testWidgets('shows {kind}: {text}', (tester) async {
      final data = UnknownRowData(
        const AgentItem(itemId: 'i1', kind: 'mystery', text: 'huh'),
      );
      await _pump(tester, UnknownRow(data: data));

      expect(find.text('mystery: huh'), findsOneWidget);
    });
  });
}
