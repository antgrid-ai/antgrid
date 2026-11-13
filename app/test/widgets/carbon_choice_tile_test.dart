import 'dart:ui' show Tristate;

import 'package:antgrid/widgets/carbon_choice_tile.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(),
    child: CarbonTheme(
      data: CarbonThemeData(),
      child: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  testWidgets('a press reaches onPressed', (tester) async {
    var presses = 0;
    await tester.pumpWidget(
      _harness(
        CarbonChoiceTile(
          label: 'Large',
          selected: false,
          onPressed: () => presses++,
        ),
      ),
    );
    await tester.tap(find.text('Large'));
    await tester.pump();
    expect(presses, 1);
  });

  testWidgets('selected announces itself and carries a check mark', (
    tester,
  ) async {
    Future<void> pump(bool selected) => tester.pumpWidget(
      _harness(
        CarbonChoiceTile(
          label: 'Large',
          selected: selected,
          onPressed: () {},
        ),
      ),
    );
    Tristate state() => tester
        .getSemantics(find.bySemanticsLabel('Large'))
        .getSemanticsData()
        .flagsCollection
        .isSelected;

    bool checkShown() => tester
        .widget<Visibility>(
          find.ancestor(
            of: find.byType(CarbonIcon),
            matching: find.byType(Visibility),
          ),
        )
        .visible;

    await pump(false);
    expect(state(), Tristate.isFalse);
    expect(checkShown(), isFalse);

    await pump(true);
    expect(state(), Tristate.isTrue);
    expect(checkShown(), isTrue);
  });

  testWidgets('the preview widget and detail are drawn', (tester) async {
    await tester.pumpWidget(
      _harness(
        CarbonChoiceTile(
          label: 'Mono',
          detail: 'IBM Plex Mono',
          selected: false,
          onPressed: () {},
          preview: const SizedBox(key: ValueKey('preview'), height: 12),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('preview')), findsOneWidget);
    expect(find.text('IBM Plex Mono'), findsOneWidget);
  });

  testWidgets('the tile keeps its size when selected', (tester) async {
    Future<Size> sizeWhen(bool selected) async {
      await tester.pumpWidget(
        _harness(
          CarbonChoiceTile(
            label: 'Large',
            selected: selected,
            onPressed: () {},
          ),
        ),
      );
      return tester.getSize(find.byType(CarbonChoiceTile));
    }

    expect(await sizeWhen(true), await sizeWhen(false));
  });
}
