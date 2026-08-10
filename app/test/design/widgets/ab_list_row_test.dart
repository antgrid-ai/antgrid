import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_harness.dart';

const _long =
    'A title long enough that it cannot possibly survive on a single line at '
    'any reasonable row width, which is exactly the point of measuring it.';

Future<double> _titleHeight(WidgetTester tester, {int? maxLines}) async {
  await pumpAntgrid(
    tester,
    SizedBox(
      width: 300,
      child: AbListRow(
        title: const Text(_long),
        titleMaxLines: maxLines ?? 1,
      ),
    ),
  );
  return tester.getSize(find.text(_long)).height;
}

void main() {
  // Every dense list in the app leans on this default; raising it would grow
  // all of them at once.
  testWidgets('a title stays on one line unless asked otherwise', (
    tester,
  ) async {
    final single = await _titleHeight(tester);
    final wrapped = await _titleHeight(tester, maxLines: 3);
    expect(wrapped, greaterThan(single));
  });

  testWidgets('subtitle wrapping is opt-in the same way', (tester) async {
    await pumpAntgrid(
      tester,
      const SizedBox(
        width: 300,
        child: AbListRow(title: Text('t'), subtitle: Text(_long)),
      ),
    );
    final single = tester.getSize(find.text(_long)).height;

    await pumpAntgrid(
      tester,
      const SizedBox(
        width: 300,
        child: AbListRow(
          title: Text('t'),
          subtitle: Text(_long),
          subtitleMaxLines: 2,
        ),
      ),
    );
    expect(tester.getSize(find.text(_long)).height, greaterThan(single));
  });
}
