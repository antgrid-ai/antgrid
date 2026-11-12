import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

BoxBorder? _tabBorder(WidgetTester tester, String label) {
  final box = tester.widget<DecoratedBox>(
    find
        .ancestor(of: find.text(label), matching: find.byType(DecoratedBox))
        .first,
  );
  return (box.decoration as BoxDecoration).border;
}

void main() {
  group('static contained list row', () {
    testWidgets('announces the selected state it paints', (tester) async {
      await pumpCarbon(
        tester,
        const CarbonContainedList(
          label: 'Env',
          children: [
            CarbonContainedListRow(title: 'A', selected: false),
            CarbonContainedListRow(title: 'B', selected: true),
          ],
        ),
      );
      expect(
        tester.getSemantics(find.text('A')).flagsCollection.isSelected,
        Tristate.isFalse,
      );
      expect(
        tester.getSemantics(find.text('B')).flagsCollection.isSelected,
        Tristate.isTrue,
      );
    });
  });

  group('truncated tag', () {
    testWidgets('does not repeat its label as a tooltip', (tester) async {
      const text = 'A very long tag label that truncates';
      await pumpCarbon(
        tester,
        Align(
          alignment: AlignmentDirectional.topStart,
          child: SizedBox(
            width: 120,
            child: CarbonTag(label: text, onPressed: () {}),
          ),
        ),
      );
      final data = tester.getSemantics(find.text(text)).getSemanticsData();
      expect(data.label, text);
      expect(data.tooltip, isNot(text));
    });
  });

  group('contained tabs rule', () {
    const tabs = <CarbonOption<String>>[
      CarbonOption(value: 'a', label: 'Alpha'),
      CarbonOption(value: 'b', label: 'Beta'),
    ];
    for (final dir in TextDirection.values) {
      testWidgets('sits on the end edge in $dir', (tester) async {
        await pumpCarbon(
          tester,
          CarbonTabs<String>(
            tabs: tabs,
            value: 'a',
            variant: CarbonTabsVariant.contained,
            onChanged: (_) {},
          ),
          dir: dir,
        );
        final border = _tabBorder(tester, 'Beta')!.dimensions.resolve(dir);
        final rule = dir == TextDirection.ltr ? border.right : border.left;
        final other = dir == TextDirection.ltr ? border.left : border.right;
        expect(rule, 1.0);
        expect(other, 0.0);
      });
    }
  });
}
