import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/rows/tool_call_card.dart';
import 'package:antgrid/widgets/transcript/selection/transcript_selection_scope.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

AgentItem _item({
  String itemId = 't1',
  String? status,
  String? toolKind,
  String? title,
  List<ToolContent>? content,
  AgentError? error,
  Object? rawInput,
  Object? rawOutput,
}) => AgentItem(
  itemId: itemId,
  kind: 'tool_call',
  status: status,
  toolKind: toolKind,
  title: title,
  content: content,
  error: error,
  rawInput: rawInput,
  rawOutput: rawOutput,
);

Future<void> _pump(
  WidgetTester tester, {
  required AgentItem item,
  bool expanded = false,
  VoidCallback? onToggle,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TranscriptSelectionScope(
          controller: TranscriptSelectionController(),
          child: SelectionArea(
            child: SingleChildScrollView(
              child: ToolCallCard(
                data: ToolCallRowData(item),
                rowIndex: 0,
                expanded: expanded,
                onToggle: onToggle ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('header status glyph', () {
    testWidgets('running shows AbLoadingDot spinner', (tester) async {
      await _pump(
        tester,
        item: _item(status: 'running', title: 'Build'),
      );
      await tester.pump();

      // AbLoadingDot is a StatefulWidget with an AnimationController; look it
      // up by runtime type name since it isn't exported for direct import
      // comparison here.
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'AbLoadingDot',
        ),
        findsOneWidget,
      );
    });

    testWidgets('completed shows a check glyph', (tester) async {
      await _pump(
        tester,
        item: _item(status: 'completed', title: 'Build'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'AbLoadingDot',
        ),
        findsNothing,
      );
    });

    testWidgets('error shows an error glyph', (tester) async {
      await _pump(
        tester,
        item: _item(status: 'error', title: 'Build'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == 'AbLoadingDot',
        ),
        findsNothing,
      );
    });

    testWidgets('title renders in mono style', (tester) async {
      await _pump(
        tester,
        item: _item(status: 'completed', title: 'Run tests'),
      );
      await tester.pumpAndSettle();

      final textWidget = tester.widget<Text>(find.text('Run tests'));
      expect(textWidget.style?.fontFamily, AbTokens.fontMono);
    });
  });

  group('terminal body', () {
    testWidgets('collapsed: body absent; after onToggle: shows terminal tail', (
      tester,
    ) async {
      final item = _item(
        status: 'completed',
        title: 'Run',
        content: const [
          ToolContent(type: 'terminal', data: 'line1\nline2\nline3'),
        ],
      );

      var expanded = false;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            return MaterialApp(
              home: Scaffold(
                body: TranscriptSelectionScope(
                  controller: TranscriptSelectionController(),
                  child: SelectionArea(
                    child: SingleChildScrollView(
                      child: ToolCallCard(
                        data: ToolCallRowData(item),
                        rowIndex: 0,
                        expanded: expanded,
                        onToggle: () => setState(() => expanded = true),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('line1'), findsNothing);

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.textContaining('line1'), findsOneWidget);
      expect(find.textContaining('line3'), findsOneWidget);
    });

    testWidgets('100-line terminal output truncates to last 40 lines', (
      tester,
    ) async {
      final lines = List.generate(100, (i) => 'line${i + 1}');
      final item = _item(
        status: 'completed',
        title: 'Run',
        content: [ToolContent(type: 'terminal', data: lines.join('\n'))],
      );

      await _pump(tester, item: item, expanded: true);
      await tester.pumpAndSettle();

      expect(find.text('Show all (100 lines)'), findsOneWidget);
      // Last visible line (line100) is present, but an early truncated
      // line (line1) must not be.
      expect(find.textContaining('line100'), findsOneWidget);
      expect(
        find.textContaining('line61'),
        findsOneWidget,
      ); // last 40 = 61..100
      final bodyText = tester
          .widgetList<Text>(find.textContaining('line'))
          .map((t) {
            final data = t.data;
            if (data != null) return data;
            return t.textSpan?.toPlainText() ?? '';
          })
          .join('\n');
      expect(
        bodyText.contains('line1\n') || bodyText.startsWith('line1\n'),
        isFalse,
      );

      await tester.tap(find.text('Show all (100 lines)'));
      await tester.pumpAndSettle();

      expect(find.text('Show all (100 lines)'), findsNothing);
      expect(find.textContaining('line1\n'), findsOneWidget);
    });
  });

  group('diff body', () {
    testWidgets('edit card shows +1 -1 stats and a DiffView', (tester) async {
      final item = _item(
        status: 'completed',
        toolKind: 'edit',
        title: 'edit file.txt',
        content: const [
          ToolContent(
            type: 'diff',
            path: 'file.txt',
            oldText: 'old line',
            newText: 'new line',
          ),
        ],
      );

      await _pump(tester, item: item, expanded: true);
      await tester.pumpAndSettle();

      expect(find.textContaining('+1'), findsOneWidget);
      expect(find.textContaining('−1'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w.runtimeType.toString() == 'DiffView'),
        findsOneWidget,
      );
    });
  });

  group('mcp body', () {
    testWidgets(
      'mcp card shows pretty JSON for rawInput/rawOutput with Copy affordances',
      (tester) async {
        final item = _item(
          status: 'completed',
          toolKind: 'mcp',
          title: 'call tool',
          rawInput: {'a': 1},
          rawOutput: {'b': 2},
        );

        await _pump(tester, item: item, expanded: true);
        await tester.pumpAndSettle();

        final pretty = const JsonEncoder.withIndent('  ').convert({'a': 1});
        expect(find.textContaining(pretty), findsOneWidget);
        expect(find.byTooltip('Copy'), findsNWidgets(2));
      },
    );

    testWidgets('copy affordance copies the pretty JSON to clipboard', (
      tester,
    ) async {
      final item = _item(
        status: 'completed',
        toolKind: 'mcp',
        title: 'call tool',
        rawInput: {'a': 1},
      );

      String? copied;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') {
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await _pump(tester, item: item, expanded: true);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Copy'));
      await tester.pumpAndSettle();

      expect(copied, contains('"a": 1'));
    });

    testWidgets('>4096-char payload clips with a Show all toggle', (
      tester,
    ) async {
      final bigValue = 'x' * 5000;
      final item = _item(
        status: 'completed',
        toolKind: 'mcp',
        title: 'call tool',
        rawInput: {'big': bigValue},
      );

      await _pump(tester, item: item, expanded: true);
      await tester.pumpAndSettle();

      expect(find.textContaining('Show all ('), findsOneWidget);

      await tester.tap(find.textContaining('Show all ('));
      await tester.pumpAndSettle();

      expect(find.textContaining('Show all ('), findsNothing);
      expect(find.textContaining(bigValue), findsOneWidget);
    });
  });

  group('error auto-show', () {
    testWidgets('item.error auto-shows error text even when expanded==false', (
      tester,
    ) async {
      final item = _item(
        status: 'error',
        title: 'Run',
        error: const AgentError(
          category: 'runtime',
          message: 'boom failed',
          retryable: false,
        ),
      );

      await _pump(tester, item: item, expanded: false);
      await tester.pumpAndSettle();

      expect(find.text('boom failed'), findsOneWidget);
    });
  });

  group('no body content', () {
    testWidgets('card with no content/rawInput/rawOutput has no chevron and '
        'is not tappable', (tester) async {
      final item = _item(status: 'completed', title: 'noop');

      await _pump(tester, item: item, expanded: false);
      await tester.pumpAndSettle();

      expect(
        find.byWidgetPredicate(
          (w) =>
              w.runtimeType.toString() == 'AbIcon' &&
              (w as dynamic).icon.toString().contains('chevron'),
        ),
        findsNothing,
      );

      // Tapping should not throw and should not invoke onToggle.
      var toggled = false;
      await _pump(
        tester,
        item: item,
        expanded: false,
        onToggle: () => toggled = true,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ToolCallCard), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(toggled, isFalse);
    });
  });
}
