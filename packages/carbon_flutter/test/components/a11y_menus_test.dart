import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  testWidgets('an icon-only button carries its name once, not as label and tooltip', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      Align(
        alignment: AlignmentDirectional.topStart,
        child: CarbonOverflowMenu(
          entries: <CarbonMenuEntry>[
            CarbonMenuItem(label: 'Rename', onPressed: () {}),
          ],
        ),
      ),
      size: const Size(800, 600),
    );
    final node = tester.getSemantics(find.bySemanticsLabel('Options'));
    final data = node.getSemanticsData();
    expect(data.label, 'Options');
    expect(data.tooltip, isEmpty);
    handle.dispose();
  });

  testWidgets('a long shortcut shares the row at 320 width and 2.0 text scale', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      Align(
        alignment: AlignmentDirectional.topStart,
        child: CarbonMenuButton(
          label: 'Actions',
          entries: <CarbonMenuEntry>[
            CarbonMenuItem(
              label: 'Copy path',
              shortcut: 'Ctrl+Shift+C',
              onPressed: () {},
            ),
          ],
        ),
      ),
      textScale: 2,
      size: const Size(320, 640),
    );
    await tester.tap(find.text('Actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.text('Copy path')).width, greaterThan(0));
    expect(
      tester.getRect(find.text('Ctrl+Shift+C')).right,
      lessThanOrEqualTo(320),
    );
  });
}
