import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/widgets/code_syntax.dart';
import 'package:antgrid/widgets/diff_viewer.dart';

/// A hunk whose code lines are far wider than any pane the app renders in.
const _longLine =
    'final String greeting = '
    "'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';";

final _diff =
    '''
diff --git a/lib/a.dart b/lib/a.dart
index 1111111..2222222 100644
--- a/lib/a.dart
+++ b/lib/a.dart
@@ -1,3 +1,3 @@
 void main() {
-  print('old');
+  $_longLine
 }
''';

/// Long enough to outrun any pane in these tests, so the vertical list has
/// somewhere to creep to. The short `}` line comes first, where it stays on
/// screen at scroll offset zero.
final _tallDiff =
    '''
@@ -1,32 +1,32 @@
 }
+  $_longLine
${List.generate(30, (i) => ' const filler = $i;').join('\n')}
''';

Widget _host({
  double width = 320,
  double height = 400,
  String? diff,
  TextScaler textScaler = TextScaler.noScaling,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: SizedBox(
          width: width,
          height: height,
          child: DiffViewer(
            path: 'lib/a.dart',
            gitStatus: 'M',
            diff: diff ?? _diff,
            additions: 1,
            deletions: 1,
            onViewFile: () {},
            onClose: () {},
            onSendToAgent: (context, message) async {},
          ),
        ),
      ),
    ),
  ),
);

/// A point inside the diff BODY — the header owns the top of the widget, and
/// the body's own box is wider than the viewport, so neither centre is usable.
Offset _inBody(WidgetTester tester) {
  final rect = tester.getRect(find.byType(DiffViewer));
  return Offset(rect.left + 20, rect.bottom - 20);
}

Finder _codeText(String startsWith) => find.byWidgetPredicate(
  (w) => w is Text && (w.textSpan?.toPlainText() ?? '').startsWith(startsWith),
);

ScrollPosition _axis(WidgetTester tester, AxisDirection direction) => tester
    .state<ScrollableState>(
      find.byWidgetPredicate(
        (w) => w is Scrollable && w.axisDirection == direction,
      ),
    )
    .position;

void main() {
  group('DiffViewer', () {
    testWidgets('renders code at the file viewer\'s size, never wrapped', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      final line = tester.widget<Text>(_codeText('  final String greeting'));
      expect(line.softWrap, isFalse);
      expect(line.maxLines, 1);
      // The whole point of sharing kCodeFontSize: a file and its diff must not
      // read at two different sizes.
      expect(line.textSpan!.style!.fontSize, kCodeFontSize);
    });

    testWidgets('a long line scrolls sideways instead of being squeezed', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(
        _axis(tester, AxisDirection.right).maxScrollExtent,
        greaterThan(0),
      );

      // Touch drag — the phone/tablet case, where the pane is narrowest and a
      // viewer that only reflowed would have nothing left to show.
      final gesture = await tester.startGesture(
        _inBody(tester),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-16, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_axis(tester, AxisDirection.right).pixels, greaterThan(0));
      expect(_axis(tester, AxisDirection.down).pixels, 0);
    });

    testWidgets('scrolls on both axes, and a sideways scroll stays sideways', (
      tester,
    ) async {
      await tester.pumpWidget(_host(height: 120));
      await tester.pumpAndSettle();

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(_inBody(tester)));

      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 40)));
      await tester.pumpAndSettle();
      expect(_axis(tester, AxisDirection.down).pixels, greaterThan(0));
      expect(_axis(tester, AxisDirection.right).pixels, 0);

      final settled = _axis(tester, AxisDirection.down).pixels;

      // A trackpad swipe is never perfectly straight; the drift must not drag
      // the diff up and down while the user is reading across a long line.
      await tester.sendEventToBinding(pointer.scroll(const Offset(60, 4)));
      await tester.pumpAndSettle();
      expect(_axis(tester, AxisDirection.right).pixels, greaterThan(0));
      expect(_axis(tester, AxisDirection.down).pixels, settled);
    });

    testWidgets('a sideways scroll over a row\'s blank pixels stays sideways', (
      tester,
    ) async {
      await tester.pumpWidget(_host(diff: _tallDiff, height: 200));
      await tester.pumpAndSettle();
      // A diff short enough to fit cannot fail this test — the list has no
      // vertical extent to creep along.
      expect(_axis(tester, AxisDirection.down).maxScrollExtent, greaterThan(0));

      // Part of every diff row paints nothing — here the gap between the
      // gutter and the code column. A row that only claimed its painted pixels
      // let that fall through to the vertical list, which is where a sideways
      // scroll started creeping up and down again.
      final code = tester.getRect(_codeText('}'));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        pointer.hover(Offset(code.left - 4, code.center.dy)),
      );

      await tester.sendEventToBinding(pointer.scroll(const Offset(60, 6)));
      await tester.pumpAndSettle();

      expect(_axis(tester, AxisDirection.right).pixels, greaterThan(0));
      expect(_axis(tester, AxisDirection.down).pixels, 0);
    });

    // The phone puts the diff on the second page of the shell's PageView,
    // whose own horizontal drag is the way back to the agent. Reading across a
    // long line has to pan the diff, not throw the user off the page — the two
    // meet in the gesture arena, where the deeper recognizer wins.
    testWidgets('a sideways drag beats the PageView the phone puts it in', (
      tester,
    ) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              controller: controller,
              children: [
                const SizedBox.expand(),
                DiffViewer(
                  path: 'lib/a.dart',
                  gitStatus: 'M',
                  diff: _diff,
                  additions: 1,
                  deletions: 1,
                  onViewFile: () {},
                  onClose: () {},
                  onSendToAgent: (context, message) async {},
                ),
              ],
            ),
          ),
        ),
      );
      controller.jumpToPage(1);
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(DiffViewer));
      final gesture = await tester.startGesture(
        Offset(rect.left + 40, rect.bottom - 40),
        kind: PointerDeviceKind.touch,
      );
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-16, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      // Scoped to the diff: the PageView is a rightward Scrollable too, which
      // is the whole point of the test.
      final panned = tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(DiffViewer),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is Scrollable && w.axisDirection == AxisDirection.right,
              ),
            ),
          )
          .position;

      expect(panned.pixels, greaterThan(0));
      expect(
        controller.page,
        1,
        reason: 'the page must not slide back to the agent',
      );
    });

    testWidgets('narrowing the pane does not change what a line says', (
      tester,
    ) async {
      await tester.pumpWidget(_host(width: 600));
      await tester.pumpAndSettle();
      final wide = tester
          .widget<Text>(_codeText('  final String greeting'))
          .textSpan!
          .toPlainText();

      await tester.pumpWidget(_host(width: 240));
      await tester.pumpAndSettle();
      final narrow = tester
          .widget<Text>(_codeText('  final String greeting'))
          .textSpan!
          .toPlainText();

      expect(narrow, wide);
    });

    testWidgets('numbers each row once, and shows both scrollbars', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.text('@@ -1,3 +1,3 @@'), findsOneWidget);
      // One gutter, not two: line 1 is the context line, and the removed and
      // added lines both sit at 2 — the removed one by where it used to be.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsNWidgets(2));

      final bars = tester.widgetList<RawScrollbar>(find.byType(RawScrollbar));
      expect(bars.length, 2);
      expect(
        bars.map((b) => b.controller).toSet().length,
        2,
        reason: 'each bar drives its own axis',
      );
    });

    // The row tint is a 15%-alpha wash and the single gutter shows the line as
    // it stands now either way, so without the marker an addition and a
    // deletion differ by colour ALONE — nothing a red/green-blind eye or a
    // washed-out screen can read.
    testWidgets('marks added and removed rows with more than colour', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();

      expect(find.text('+'), findsOneWidget);
      expect(find.text('-'), findsOneWidget);
    });

    testWidgets('lays its own measurements out at the ambient text scale', (
      tester,
    ) async {
      // Rows render through Text.rich, so the scaler reaches them whether or
      // not the hand-rolled TextPainter and the fixed row extent agree with
      // it. When they did not, a phone at 130% clipped the longest lines with
      // the horizontal extent already exhausted — the exact failure the width
      // measurement exists to prevent — and cut the descenders off every row.
      await tester.pumpWidget(_host(diff: _tallDiff));
      await tester.pumpAndSettle();
      final plainWidth = _axis(tester, AxisDirection.right).maxScrollExtent;
      final plainHeight = _axis(tester, AxisDirection.down).maxScrollExtent;
      expect(plainWidth, greaterThan(0));
      expect(plainHeight, greaterThan(0));

      // Same State, new scaler: the re-measure rides on didChangeDependencies,
      // so a UI Size change mid-diff has to move the extents too.
      await tester.pumpWidget(
        _host(diff: _tallDiff, textScaler: const TextScaler.linear(1.6)),
      );
      await tester.pumpAndSettle();

      // Well under the 1.6 the scaler applies — the fixed spacing either side
      // of the code column dilutes it, and the assertion only has to separate
      // "scaled" from the unchanged extents an unscaled measurement gives.
      expect(
        _axis(tester, AxisDirection.right).maxScrollExtent,
        greaterThan(plainWidth * 1.3),
      );
      expect(
        _axis(tester, AxisDirection.down).maxScrollExtent,
        greaterThan(plainHeight * 1.3),
      );
    });

    testWidgets('binary diffs still short-circuit to the empty state', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DiffViewer(
              path: 'assets/logo.png',
              diff: 'Binary files a/assets/logo.png and b/... differ',
              additions: 0,
              deletions: 0,
              onViewFile: () {},
              onClose: () {},
              onSendToAgent: (context, message) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Binary file changed: logo.png'), findsOneWidget);
    });
  });
}
