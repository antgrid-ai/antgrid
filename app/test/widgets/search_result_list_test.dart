import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/search_models.dart';
import 'package:antgrid/widgets/search_result_list.dart';

SearchMatch _match(
  int line, {
  int column = 1,
  String content = 'needle',
}) => SearchMatch(
  line: line,
  column: column,
  lineContent: content,
  contextBefore: const [],
  contextAfter: const [],
);

Widget _host(
  List<SearchFileGroup> results, {
  String query = 'needle',
  bool isRegex = false,
  bool caseSensitive = false,
  void Function(String, int, int)? onMatchTap,
}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 480,
      height: 400,
      child: SearchResultList(
        results: results,
        query: query,
        isRegex: isRegex,
        caseSensitive: caseSensitive,
        onMatchTap: onMatchTap ?? (_, _, _) {},
      ),
    ),
  ),
);

List<SearchFileGroup> _twoFiles() => [
  SearchFileGroup(path: 'a.dart', matches: [_match(101), _match(102)]),
  SearchFileGroup(path: 'b.dart', matches: [_match(203, column: 7)]),
];

List<String> _highlights(WidgetTester tester, String line) {
  final rich = tester.widget<RichText>(
    find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == line,
    ),
  );
  return [
    for (final span in (rich.text as TextSpan).children ?? const [])
      if (span is TextSpan && span.style?.backgroundColor != null) span.text!,
  ];
}

void main() {
  testWidgets('rows of a long file build only as they scroll into view', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        SearchFileGroup(
          path: 'big.txt',
          matches: [for (var i = 1; i <= 100; i++) _match(1000 + i)],
        ),
      ]),
    );
    final last = find.text('1100', skipOffstage: false);
    expect(find.text('1001'), findsOneWidget);
    expect(last, findsNothing);

    // The extent is estimated from the rows built so far, so one jump to it
    // can land short of the end.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable))
        .position;
    for (var i = 0; i < 5 && last.evaluate().isEmpty; i++) {
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
    }
    expect(last, findsOneWidget);
  });

  testWidgets("each file's rows sit directly under its own header in arrival "
      'order', (tester) async {
    await tester.pumpWidget(_host(_twoFiles()));

    final ys = [
      for (final text in ['a.dart', '101', '102', 'b.dart', '203'])
        tester.getTopLeft(find.text(text)).dy,
    ];
    for (var i = 1; i < ys.length; i++) {
      expect(ys[i], greaterThan(ys[i - 1]));
    }
  });

  testWidgets('a collapsed file keeps its match count and stays collapsed as '
      'more matches stream in, and expanding restores its rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        SearchFileGroup(path: 'a.dart', matches: [_match(101)]),
      ]),
    );
    await tester.tap(find.text('a.dart'));
    await tester.pump();

    await tester.pumpWidget(_host(_twoFiles()));
    expect(find.text('101'), findsNothing);
    expect(find.text('102'), findsNothing);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('▶'), findsOneWidget);
    expect(find.text('203'), findsOneWidget);

    await tester.tap(find.text('a.dart'));
    await tester.pump();
    expect(find.text('101'), findsOneWidget);
    expect(find.text('102'), findsOneWidget);
    expect(find.text('▶'), findsNothing);
    expect(find.text('▼'), findsNWidgets(2));
  });

  testWidgets('tapping a match row reports its file, line and column', (
    tester,
  ) async {
    final calls = <(String, int, int)>[];
    await tester.pumpWidget(
      _host(_twoFiles(), onMatchTap: (p, l, c) => calls.add((p, l, c))),
    );

    await tester.tap(find.text('203'));
    await tester.pump();
    expect(calls, [('b.dart', 203, 7)]);

    await tester.tap(find.text('b.dart'));
    await tester.pump();
    expect(calls, hasLength(1));
  });

  testWidgets('a case-insensitive search highlights every occurrence in the '
      "line's own casing, a case-sensitive one only the exact casing, and a "
      'regex one nothing', (tester) async {
    const line = 'a Foo b FOO c';
    for (final (query, caseSensitive, isRegex, expected) in [
      ('FoO', false, false, ['Foo', 'FOO']),
      ('FOO', true, false, ['FOO']),
      ('F.O', false, true, <String>[]),
    ]) {
      await tester.pumpWidget(
        _host(
          [
            SearchFileGroup(path: 'a.dart', matches: [_match(1, content: line)]),
          ],
          query: query,
          caseSensitive: caseSensitive,
          isRegex: isRegex,
        ),
      );
      expect(_highlights(tester, line), expected, reason: 'query $query');
    }
  });
}
