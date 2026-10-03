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

Finder _highlightedLine(String line) => find.byWidgetPredicate(
  (w) =>
      w is RichText &&
      w.text.toPlainText() == line &&
      (w.text as TextSpan).children != null,
);

List<String> _highlights(WidgetTester tester, String line) {
  final rich = tester.widget<RichText>(_highlightedLine(line));
  return [
    for (final span in (rich.text as TextSpan).children!.cast<TextSpan>())
      if (span.style?.backgroundColor != null) span.text!,
  ];
}

void main() {
  testWidgets('rows of a long file build only as they scroll into view', (
    tester,
  ) async {
    final group = SearchFileGroup(
      path: 'big.txt',
      matches: [
        for (var i = 0; i < 500; i++) _match(10001 + i, content: 'needle $i'),
      ],
    );
    await tester.pumpWidget(_host([group]));

    expect(find.text('10001'), findsOneWidget);
    final built = find
        .byWidgetPredicate(
          (w) => w is Text && RegExp(r'^1\d{4}$').hasMatch(w.data ?? ''),
          skipOffstage: false,
        )
        .evaluate()
        .length;
    expect(built, lessThan(100));
    expect(find.text('10500', skipOffstage: false), findsNothing);

    await tester.scrollUntilVisible(
      find.text('10500'),
      400,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 200,
    );
    expect(find.text('10500'), findsOneWidget);
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

  testWidgets('collapsing a file hides its rows but keeps its match count, and '
      'expanding restores them', (tester) async {
    await tester.pumpWidget(_host(_twoFiles()));

    await tester.tap(find.text('a.dart'));
    await tester.pump();
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

  testWidgets('a collapsed file stays collapsed as more of its matches stream '
      'in', (tester) async {
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
    expect(find.text('203'), findsOneWidget);
    expect(find.text('▶'), findsOneWidget);
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

  group('highlighting', () {
    const line = 'a Foo b FOO c';
    List<SearchFileGroup> oneLine() => [
      SearchFileGroup(path: 'a.dart', matches: [_match(1, content: line)]),
    ];

    testWidgets("a case-insensitive search highlights every occurrence in the "
        "line's own casing", (tester) async {
      await tester.pumpWidget(_host(oneLine(), query: 'FoO'));

      expect(_highlights(tester, line), ['Foo', 'FOO']);
    });

    testWidgets('a case-sensitive search highlights only the exact casing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(oneLine(), query: 'FOO', caseSensitive: true),
      );

      expect(_highlights(tester, line), ['FOO']);
    });

    testWidgets('a regex search renders the line without highlights', (
      tester,
    ) async {
      await tester.pumpWidget(_host(oneLine(), query: 'F.O', isRegex: true));

      expect(
        find.byWidgetPredicate((w) => w is Text && w.data == line),
        findsOneWidget,
      );
      expect(_highlightedLine(line), findsNothing);
    });
  });
}
