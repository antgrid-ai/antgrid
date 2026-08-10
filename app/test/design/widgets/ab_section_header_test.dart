import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_section_header.dart';
import 'package:antgrid/design/widgets/ab_separator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_harness.dart';

void main() {
  testWidgets('the label is uppercased and the count rides beside it', (
    tester,
  ) async {
    await pumpAntgrid(
      tester,
      const AbSectionHeader(label: 'Needs you', count: 3),
    );
    expect(find.text('NEEDS YOU'), findsOneWidget);
    expect(find.text('· 3'), findsOneWidget);
  });

  // An activity feed has no total worth stating; a `· 0` there would read as a
  // count of nothing rather than as an unbounded run.
  testWidgets('no count means no separator dot', (tester) async {
    await pumpAntgrid(tester, const AbSectionHeader(label: 'Activity'));
    expect(find.text('ACTIVITY'), findsOneWidget);
    expect(find.textContaining('·'), findsNothing);
  });

  testWidgets('the rule is opt-in', (tester) async {
    await pumpAntgrid(tester, const AbSectionHeader(label: 'Sessions'));
    expect(find.byType(AbSeparator), findsNothing);

    await pumpAntgrid(
      tester,
      const AbSectionHeader(label: 'Sessions', rule: true),
    );
    expect(find.byType(AbSeparator), findsOneWidget);
  });

  // The drawer groups by machine and by project, so a name with no bound of its
  // own lands here.
  testWidgets('a long label ellipsizes rather than overflowing', (
    tester,
  ) async {
    await pumpAntgrid(
      tester,
      const SizedBox(
        width: 120,
        child: AbSectionHeader(
          label: 'a machine name far wider than the panel holding it',
          count: 9,
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('· 9'), findsOneWidget);
  });

  testWidgets('the font follows the mono flag', (tester) async {
    await pumpAntgrid(tester, const AbSectionHeader(label: 'x'));
    expect(
      tester.widget<Text>(find.text('X')).style?.fontFamily,
      AbTokens.fontSans,
    );

    await pumpAntgrid(tester, const AbSectionHeader(label: 'x', mono: true));
    expect(
      tester.widget<Text>(find.text('X')).style?.fontFamily,
      AbTokens.fontMono,
    );
  });

  group('pinned', () {
    // The whole reason the pinned variant exists: rows scroll UNDER it, so a
    // header that let them through would be unreadable exactly while the user
    // is scrolling past it.
    testWidgets('it stays on screen while its rows scroll away', (
      tester,
    ) async {
      await pumpAntgrid(
        tester,
        CustomScrollView(
          slivers: [
            const AbSliverSectionHeader(
              label: 'Activity',
              background: Color(0xFF000000),
            ),
            SliverList.list(
              children: [
                for (var i = 0; i < 60; i++)
                  SizedBox(height: 40, child: Text('row $i')),
              ],
            ),
          ],
        ),
      );
      expect(find.text('ACTIVITY'), findsOneWidget);

      await tester.drag(find.text('row 0'), const Offset(0, -800));
      await tester.pump();

      expect(find.text('row 0'), findsNothing);
      expect(find.text('ACTIVITY'), findsOneWidget);
    });
  });
}
