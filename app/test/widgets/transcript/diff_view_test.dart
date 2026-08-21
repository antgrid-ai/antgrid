import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/widgets/transcript/diff_view.dart';

Future<void> _pump(WidgetTester tester, Widget child) {
  return tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

void main() {
  test('computeLineDiff marks adds/dels/context', () {
    final d = computeLineDiff('a\nb\nc', 'a\nx\nc');
    expect(d.map((l) => '${l.op.name}:${l.text}').toList(), [
      'context:a',
      'del:b',
      'add:x',
      'context:c',
    ]);
  });

  test('null oldText means all-added via diffLinesFor', () {
    const content = ToolContent(type: 'diff', newText: 'a\nb');
    final d = diffLinesFor(content);
    expect(d.map((l) => '${l.op.name}:${l.text}').toList(), ['add:a', 'add:b']);
  });

  test('null newText means all-deleted via diffLinesFor', () {
    const content = ToolContent(type: 'diff', oldText: 'a\nb');
    final d = diffLinesFor(content);
    expect(d.map((l) => '${l.op.name}:${l.text}').toList(), ['del:a', 'del:b']);
  });

  test('diffLinesFor falls back to parsePatchText when only text is set', () {
    const content = ToolContent(type: 'diff', text: '@@ -1 +1 @@\n-b\n+x');
    final d = diffLinesFor(content);
    expect(d.map((l) => '${l.op.name}:${l.text}').toList(), ['del:b', 'add:x']);
  });

  test('diffLinesFor returns empty when nothing is set', () {
    const content = ToolContent(type: 'diff');
    expect(diffLinesFor(content), isEmpty);
  });

  testWidgets('DiffView renders styled + and - rows for old/new content', (
    tester,
  ) async {
    const content = ToolContent(
      type: 'diff',
      oldText: 'a\nb\nc',
      newText: 'a\nx\nc',
    );
    await _pump(tester, DiffView(lines: diffLinesFor(content)));
    await tester.pumpAndSettle();

    expect(find.textContaining('x'), findsOneWidget);
    expect(find.textContaining('b'), findsOneWidget);
  });

  testWidgets('DiffView does not throw for patch-text-only content', (
    tester,
  ) async {
    const content = ToolContent(type: 'diff', text: '@@ -1 +1 @@\n-b\n+x');
    await _pump(tester, DiffView(lines: diffLinesFor(content)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('x'), findsOneWidget);
  });

  testWidgets('DiffView renders nothing for empty lines', (tester) async {
    await _pump(tester, const DiffView(lines: []));
    await tester.pumpAndSettle();

    expect(find.byType(SizedBox), findsOneWidget);
  });
}
