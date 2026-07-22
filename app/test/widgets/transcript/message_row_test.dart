import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/providers/now_ticker.dart';
import 'package:antgrid/widgets/transcript/markdown_body.dart';
import 'package:antgrid/widgets/transcript/rows/message_row.dart';
import 'package:antgrid/widgets/transcript/selection/transcript_selection_scope.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

AgentItem _item({required String text, String role = 'assistant'}) =>
    AgentItem(itemId: 'i1', kind: 'message', role: role, text: text);

Future<void> _pump(WidgetTester tester, Widget child) {
  // MessageRow needs both a pinned "now" (its meta row reads nowMinuteProvider)
  // and an ambient selection scope (its SelectableBlock registers with it).
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        nowMinuteProvider.overrideWith(
          (ref) => Stream.value(DateTime(2026, 7, 3, 12, 5)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TranscriptSelectionScope(
            controller: TranscriptSelectionController(),
            child: SelectionArea(child: child),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(() {
    // markdown_widget uses VisibilityDetector which has a debounce timer.
    // Setting updateInterval to zero makes callbacks fire synchronously in
    // tests, preventing the "pending timer" assertion failure on teardown.
    VisibilityDetectorController.instance.updateInterval = Duration.zero;
  });

  testWidgets('assistant message renders TranscriptMarkdown', (tester) async {
    final data = MessageRowData(_item(text: 'hello **world**'), isUser: false);
    await _pump(tester, MessageRow(data: data, rowIndex: 0));
    await tester.pumpAndSettle();

    expect(find.byType(TranscriptMarkdown), findsOneWidget);
  });

  testWidgets(
    'user message renders plain Text inside a left-accent-bordered Container',
    (tester) async {
      final data = MessageRowData(
        _item(text: 'hi there', role: 'user'),
        isUser: true,
      );
      await _pump(tester, MessageRow(data: data, rowIndex: 0));
      await tester.pumpAndSettle();

      expect(find.byType(TranscriptMarkdown), findsNothing);
      expect(find.text('hi there'), findsOneWidget);

      final containers = tester.widgetList<Container>(find.byType(Container));
      final bordered = containers.where((c) {
        final border = c.decoration is BoxDecoration
            ? (c.decoration as BoxDecoration).border
            : null;
        return border is Border && border.left != BorderSide.none;
      });
      expect(bordered, isNotEmpty);
    },
  );

  testWidgets(
    'long user message (12 lines) shows Show more toggle that expands',
    (tester) async {
      final longText = List.generate(12, (i) => 'line $i').join('\n');
      final data = MessageRowData(
        _item(text: longText, role: 'user'),
        isUser: true,
      );
      await _pump(tester, MessageRow(data: data, rowIndex: 0));
      await tester.pumpAndSettle();

      expect(find.text('Show more'), findsOneWidget);
      expect(find.text('Show less'), findsNothing);

      await tester.tap(find.text('Show more'));
      await tester.pumpAndSettle();

      expect(find.text('Show less'), findsOneWidget);
      expect(find.text('Show more'), findsNothing);
    },
  );

  testWidgets(
    'long single-line user message (no newlines) still shows Show more toggle',
    (tester) async {
      // No newlines, but far past the character budget — must still collapse.
      final longLine = 'x' * 500;
      final data = MessageRowData(
        _item(text: longLine, role: 'user'),
        isUser: true,
      );
      await _pump(tester, MessageRow(data: data, rowIndex: 0));
      await tester.pumpAndSettle();

      expect(find.text('Show more'), findsOneWidget);
    },
  );

  testWidgets('short user message (2 lines) shows no Show more toggle', (
    tester,
  ) async {
    final shortText = 'line 0\nline 1';
    final data = MessageRowData(
      _item(text: shortText, role: 'user'),
      isUser: true,
    );
    await _pump(tester, MessageRow(data: data, rowIndex: 0));
    await tester.pumpAndSettle();

    expect(find.text('Show more'), findsNothing);
    expect(find.text('Show less'), findsNothing);
  });

  testWidgets('user message actions share the timestamp row', (tester) async {
    final data = MessageRowData(
      AgentItem(
        itemId: 'i1',
        kind: 'message',
        role: 'user',
        text: 'can you revert from here?',
      ),
      isUser: true,
      timestamp: DateTime(2026, 7, 3, 12),
    );
    await _pump(tester, MessageRow(data: data, rowIndex: 0, onRevert: () {}));
    await tester.pumpAndSettle();

    final timestampCenter = tester.getCenter(find.text('5 mins ago'));
    final revertCenter = tester.getCenter(
      find.byTooltip('Revert conversation'),
    );

    expect((timestampCenter.dy - revertCenter.dy).abs(), lessThanOrEqualTo(1));
    expect(revertCenter.dx, greaterThan(timestampCenter.dx));
  });

  testWidgets('assistant usage shares the timestamp row', (tester) async {
    final data = MessageRowData(
      _item(text: 'answer'),
      isUser: false,
      timestamp: DateTime(2026, 7, 3, 12),
      usage: const AgentTokenUsage(
        inputTokens: 1500,
        outputTokens: 200,
        totalTokens: 1700,
      ),
    );
    await _pump(tester, MessageRow(data: data, rowIndex: 0));
    await tester.pumpAndSettle();

    final timestampCenter = tester.getCenter(find.text('5 mins ago'));
    final usageCenter = tester.getCenter(
      find.text('1.5k in · 200 out · 1.7k tok'),
    );

    expect((timestampCenter.dy - usageCenter.dy).abs(), lessThanOrEqualTo(1));
    expect(usageCenter.dx, greaterThan(timestampCenter.dx));
  });

  testWidgets('assistant usage renders when timestamp is unknown', (
    tester,
  ) async {
    final data = MessageRowData(
      _item(text: 'answer'),
      isUser: false,
      usage: const AgentTokenUsage(totalTokens: 1700),
    );
    await _pump(tester, MessageRow(data: data, rowIndex: 0));
    await tester.pumpAndSettle();

    expect(find.text('1.7k tok'), findsOneWidget);
  });

  testWidgets('assistant metadata stays single-line at narrow widths', (
    tester,
  ) async {
    final data = MessageRowData(
      _item(text: 'answer'),
      isUser: false,
      timestamp: DateTime(2026, 7, 3, 12),
      usage: const AgentTokenUsage(
        inputTokens: 1500,
        outputTokens: 200,
        totalTokens: 1700,
        cacheReadTokens: 8200,
      ),
    );
    await _pump(
      tester,
      SizedBox(width: 180, child: MessageRow(data: data, rowIndex: 0)),
    );
    await tester.pumpAndSettle();

    expect(find.text('5 mins ago'), findsOneWidget);
    final usageText = tester.widget<Text>(
      find.text('1.5k in · 200 out · 1.7k tok · 8.2k cached'),
    );
    expect(usageText.maxLines, 1);
    expect(usageText.softWrap, isFalse);
    expect(usageText.overflow, TextOverflow.fade);
    expect(tester.takeException(), isNull);
  });
}
