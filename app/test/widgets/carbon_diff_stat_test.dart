import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/widgets/carbon_diff_stat.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  CarbonDensity density = CarbonDensity.compact,
  double textScale = 1.0,
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
        child: Scaffold(body: Center(child: child)),
      ),
    ),
  );
}

Text _text(WidgetTester tester, String data) =>
    tester.widget<Text>(find.text(data));

void main() {
  testWidgets('renders both parts with a true minus sign', (tester) async {
    await _pump(
      tester,
      const CarbonDiffStat(additions: 12, deletions: 3),
    );

    expect(find.text('+12'), findsOneWidget);
    expect(find.text('−3'), findsOneWidget);
    expect(find.text('-3'), findsNothing);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('omits a zero part', (tester) async {
    await _pump(tester, const CarbonDiffStat(additions: 4, deletions: 0));
    expect(find.text('+4'), findsOneWidget);
    expect(find.textContaining('−'), findsNothing);

    await _pump(tester, const CarbonDiffStat(additions: 0, deletions: 9));
    expect(find.textContaining('+'), findsNothing);
    expect(find.text('−9'), findsOneWidget);
  });

  testWidgets('renders nothing and says nothing when both are zero', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const CarbonDiffStat(additions: 0, deletions: 0));

    expect(find.byType(Text), findsNothing);
    expect(
      tester.getSize(find.byType(CarbonDiffStat)),
      Size.zero,
    );
    expect(find.semantics.byLabel(RegExp('added|removed')), findsNothing);
    handle.dispose();
  });

  testWidgets('groups thousands', (tester) async {
    await _pump(tester, const CarbonDiffStat(additions: 2728, deletions: 15000));

    expect(find.text('+2,728'), findsOneWidget);
    expect(find.text('−15,000'), findsOneWidget);
    expect(CarbonDiffStat.formatCount(999), '999');
    expect(CarbonDiffStat.formatCount(1000), '1,000');
  });

  testWidgets('speaks as one node and hides the glyph text', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, const CarbonDiffStat(additions: 12, deletions: 3));

    expect(find.bySemanticsLabel('12 added, 3 removed'), findsOneWidget);
    expect(find.semantics.byLabel('+12'), findsNothing);
    expect(find.semantics.byLabel('−3'), findsNothing);

    await _pump(tester, const CarbonDiffStat(additions: 0, deletions: 3));
    expect(find.bySemanticsLabel('3 removed'), findsOneWidget);
    handle.dispose();
  });

  test('describe omits zero parts consistently with the visual', () {
    expect(CarbonDiffStat.describe(1, 2), '1 added, 2 removed');
    expect(CarbonDiffStat.describe(1, 0), '1 added');
    expect(CarbonDiffStat.describe(0, 2), '2 removed');
    expect(CarbonDiffStat.describe(0, 0), '');
  });

  for (final brightness in Brightness.values) {
    testWidgets('colours follow the support tokens, ${brightness.name}', (
      tester,
    ) async {
      await _pump(
        tester,
        const CarbonDiffStat(additions: 1, deletions: 1),
        brightness: brightness,
      );

      final colors = CarbonThemeData.forBrightness(brightness).colors;
      final added = _text(tester, '+1').style!;
      final removed = _text(tester, '−1').style!;
      expect(added.color, colors.supportSuccess);
      expect(removed.color, colors.supportError);
      expect(added.fontFamily, contains('IBM Plex Mono'));
      expect(added.fontWeight, isNot(FontWeight.w600));
      expect(abWidgetsInScope(tester), isEmpty);
    });
  }

  testWidgets('medium is larger than small', (tester) async {
    await _pump(tester, const CarbonDiffStat(additions: 1, deletions: 0));
    final small = _text(tester, '+1').style!.fontSize!;

    await _pump(
      tester,
      const CarbonDiffStat(
        additions: 1,
        deletions: 0,
        size: CarbonDiffStatSize.medium,
      ),
    );
    expect(_text(tester, '+1').style!.fontSize!, small + 2);
  });

  for (final density in CarbonDensity.values) {
    testWidgets('lays out at 2.0 text scale, ${density.name}', (tester) async {
      await _pump(
        tester,
        const CarbonDiffStat(additions: 12345, deletions: 6789),
        density: density,
        textScale: 2.0,
      );

      expect(tester.takeException(), isNull);
      expect(abWidgetsInScope(tester), isEmpty);
    });
  }
}
