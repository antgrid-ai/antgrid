import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/carbon_code_style.dart';
import 'package:antgrid/widgets/carbon_diff_stat.dart';
import 'package:antgrid/widgets/diff_viewer.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

const _diff = '''
@@ -1,3 +1,3 @@
 void main() {
-  print('old');
+  print('new');
 }
@@ -20,2 +20,2 @@
-  final a = 1;
+  final a = 2;
''';

const _binary = 'Binary files a/assets/logo.png and b/assets/logo.png differ';

Future<void> _pump(
  WidgetTester tester, {
  String diff = _diff,
  String path = 'lib/a.dart',
  int additions = 2,
  int deletions = 2,
  Brightness brightness = Brightness.light,
  CarbonDensity density = CarbonDensity.compact,
  double textScale = 1.0,
  double width = 600,
  VoidCallback? onViewFile,
  VoidCallback? onClose,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
      home: AbCarbonScope(
        density: density,
        child: Scaffold(
          body: SizedBox(
            width: width,
            height: 400,
            child: DiffViewer(
              path: path,
              gitStatus: 'M',
              diff: diff,
              additions: additions,
              deletions: deletions,
              onViewFile: onViewFile ?? () {},
              onClose: onClose ?? () {},
              onSendToAgent: (context, message) async {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('loaded diff has no Ab widgets in scope', (tester) async {
    await _pump(tester);

    expect(find.text('@@ -1,3 +1,3 @@'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('empty diff has no Ab widgets in scope', (tester) async {
    await _pump(tester, diff: '', additions: 0, deletions: 0);

    expect(find.text('No changes'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('binary placeholder has no Ab widgets in scope', (tester) async {
    await _pump(
      tester,
      diff: _binary,
      path: 'assets/logo.png',
      additions: 0,
      deletions: 0,
    );

    expect(find.text('Binary file changed: logo.png'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  for (final brightness in Brightness.values) {
    for (final density in CarbonDensity.values) {
      testWidgets('clean guard, ${brightness.name} ${density.name}', (
        tester,
      ) async {
        await _pump(tester, brightness: brightness, density: density);

        expect(abWidgetsInScope(tester), isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('header actions call back', (tester) async {
    var viewed = 0;
    var closed = 0;
    await _pump(
      tester,
      onViewFile: () => viewed++,
      onClose: () => closed++,
    );

    await tester.tap(find.byType(CarbonLink));
    await tester.tap(_iconButton('Close diff'));
    await tester.pump();

    expect(viewed, 1);
    expect(closed, 1);
  });

  testWidgets('header shows the stat and swaps the link for an icon when narrow', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.byType(CarbonDiffStat), findsOneWidget);
    expect(find.byType(CarbonLink), findsOneWidget);

    await _pump(tester, width: 300);
    expect(find.byType(CarbonLink), findsNothing);
    expect(find.byType(CarbonDiffStat), findsNothing);
    expect(_iconButton('View file'), findsOneWidget);
  });

  testWidgets('narrow touch pane at 2.0 text scale does not overflow', (
    tester,
  ) async {
    await _pump(
      tester,
      density: CarbonDensity.touch,
      width: 256,
      textScale: 2.0,
      additions: 1234,
      deletions: 567,
    );

    expect(tester.takeException(), isNull);
    expect(_iconButton('Close diff'), findsOneWidget);
  });

  testWidgets('code rows use the Carbon code style', (tester) async {
    await _pump(tester);

    final style = CarbonCodeStyle.of(tester.element(find.byType(DiffViewer)));
    final line = tester.widget<Text>(
      find.byWidgetPredicate(
        (w) =>
            w is Text &&
            (w.textSpan?.toPlainText() ?? '').startsWith('  print(\'new\')'),
      ),
    );
    expect(line.textSpan!.style!.fontFamily, style.text.fontFamily);
    expect(line.textSpan!.style!.fontSize, style.text.fontSize);
  });

  testWidgets('every row has the same extent at 1.0 and 2.0 text scale', (
    tester,
  ) async {
    for (final scale in [1.0, 2.0]) {
      await _pump(tester, textScale: scale);

      final style = CarbonCodeStyle.of(tester.element(find.byType(DiffViewer)));
      final expected =
          style.lineHeight(TextScaler.linear(scale)) + CarbonSpacing.spacing02;
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(list.itemExtent, closeTo(expected, 0.001));
      expect(tester.takeException(), isNull);
    }
  });
}

Finder _iconButton(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
);
