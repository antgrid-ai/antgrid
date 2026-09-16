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
import 'package:antgrid/widgets/agent_error_presentation.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  group('ErrorBanner', () {
    test('maps every known category and falls back for unknown values', () {
      const cases = {
        'rate_limited': 'Rate limit reached',
        'quota_exceeded': 'Usage limit reached',
        'auth': 'Sign-in required',
        'network': 'Connection interrupted',
        'context_overflow': 'Conversation too long',
        'server_error': 'Agent service error',
        'aborted': 'Request stopped',
        'future_category': 'Agent error',
      };
      for (final entry in cases.entries) {
        expect(agentErrorCategoryLabel(entry.key), entry.value);
      }
    });

    testWidgets('shows friendly category, provider, and provider message', (
      tester,
    ) async {
      final data = ErrorRowData(
        turnId: 't1',
        error: const AgentError(
          category: 'network',
          message: 'connection lost',
          retryable: false,
          provider: 'OpenAI',
        ),
      );
      await _pump(tester, ErrorBanner(data: data, onDismiss: () {}));

      expect(find.text('CONNECTION INTERRUPTED'), findsOneWidget);
      expect(find.text('OPENAI'), findsOneWidget);
      expect(find.text('connection lost'), findsOneWidget);
      expect(find.textContaining('try again'), findsNothing);
    });

    testWidgets('shows a retry delay without internal retryable wording', (
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

      expect(find.text('Try again in 30 seconds.'), findsOneWidget);
      expect(find.textContaining('retryable'), findsNothing);
    });

    testWidgets('offers another attempt when no retry delay is provided', (
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

      expect(find.text('You can try again.'), findsOneWidget);
    });

    testWidgets('an empty provider message does not add a detail row', (
      tester,
    ) async {
      final data = ErrorRowData(
        turnId: 't1',
        error: const AgentError(
          category: 'auth',
          message: '',
          retryable: false,
        ),
      );
      await _pump(tester, ErrorBanner(data: data, onDismiss: () {}));

      expect(find.text('SIGN-IN REQUIRED'), findsOneWidget);
      expect(find.text(''), findsNothing);
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
