import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/pulsing_opacity.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/rows/reasoning_block.dart';
import 'package:antgrid/widgets/transcript/selection/transcript_selection_scope.dart';
import 'package:antgrid/widgets/transcript/transcript_rows.dart';

AgentItem _item({String itemId = 'r1', String? text}) =>
    AgentItem(itemId: itemId, kind: 'reasoning', text: text);

Future<void> _pump(
  WidgetTester tester, {
  required AgentItem item,
  required bool isStreaming,
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
              child: ReasoningBlock(
                data: ReasoningRowData(item, isStreaming: isStreaming),
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
  group('streaming', () {
    testWidgets('shows Thinking… header with PulsingOpacity', (tester) async {
      await _pump(
        tester,
        item: _item(text: 'considering options'),
        isStreaming: true,
      );
      await tester.pump();

      expect(find.text('Thinking…'), findsOneWidget);
      expect(find.byType(PulsingOpacity), findsOneWidget);
    });

    testWidgets('only shows the tail preview of a long multi-line text', (
      tester,
    ) async {
      final text = List.generate(6, (i) => 'line $i').join('\n');
      await _pump(tester, item: _item(text: text), isStreaming: true);
      await tester.pump();

      // Only the last two lines should be visible; earlier lines absent.
      expect(find.text('line 4\nline 5'), findsOneWidget);
      expect(find.textContaining('line 0'), findsNothing);
      expect(find.textContaining('line 3'), findsNothing);
    });
  });

  group('settled + collapsed', () {
    testWidgets('shows "Thought" header and hides the text', (tester) async {
      await _pump(
        tester,
        item: _item(text: 'full reasoning text here'),
        isStreaming: false,
      );
      await tester.pump();

      expect(find.text('Thought'), findsOneWidget);
      expect(find.text('full reasoning text here'), findsNothing);
    });
  });

  group('settled + expanded', () {
    testWidgets('shows full text after onToggle flips expanded and re-pump', (
      tester,
    ) async {
      var expanded = false;
      final item = _item(text: 'full reasoning text here');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TranscriptSelectionScope(
              controller: TranscriptSelectionController(),
              child: SelectionArea(
                child: StatefulBuilder(
                  builder: (context, setState) {
                    return SingleChildScrollView(
                      child: ReasoningBlock(
                        data: ReasoningRowData(item, isStreaming: false),
                        rowIndex: 0,
                        expanded: expanded,
                        onToggle: () => setState(() => expanded = true),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('full reasoning text here'), findsNothing);

      await tester.tap(find.text('Thought'));
      await tester.pump();

      expect(find.text('full reasoning text here'), findsOneWidget);
    });
  });
}
