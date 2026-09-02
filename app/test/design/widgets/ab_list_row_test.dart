import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test_harness.dart';

const _long =
    'A title long enough that it cannot possibly survive on a single line at '
    'any reasonable row width, which is exactly the point of measuring it.';

/// Vertical padding an [AbRowDensity.sm] row adds around its content, so a
/// measured row height can be reduced to the content the floor acts on.
const _smPadding = AbTokens.space6 * 2;

Future<double> _titleHeight(WidgetTester tester, {int? maxLines}) async {
  await pumpAntgrid(
    tester,
    SizedBox(
      width: 300,
      child: AbListRow(title: const Text(_long), titleMaxLines: maxLines ?? 1),
    ),
  );
  return tester.getSize(find.text(_long)).height;
}

/// Height of a `sm` row carrying [floor], optionally with a subtitle (which
/// makes its natural content taller than an icon button) and at [scale].
Future<double> _rowHeight(
  WidgetTester tester, {
  required AbRowContentFloor floor,
  double scale = 1.0,
  bool subtitle = false,
}) async {
  await pumpAntgrid(
    tester,
    Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: SizedBox(
          width: 300,
          child: AbListRow(
            title: const Text('project-name'),
            subtitle: subtitle ? const Text('main') : null,
            density: AbRowDensity.sm,
            contentFloor: floor,
          ),
        ),
      ),
    ),
  );
  return tester.getSize(find.byType(AbListRow)).height;
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

  group('AbRowContentFloor', () {
    testWidgets('none leaves a short row at its natural content height', (
      tester,
    ) async {
      // The floor is opt-in and every other list in the app declines it, so
      // this is the guard for ~24 call sites at once.
      expect(
        const AbListRow(title: Text('t')).contentFloor,
        AbRowContentFloor.none,
      );

      final height = await _rowHeight(tester, floor: AbRowContentFloor.none);
      final title = tester.getSize(find.text('project-name')).height;

      expect(title, lessThan(AbTokens.iconButtonBox));
      expect(height, closeTo(title + _smPadding, 0.01));
    });

    testWidgets('iconButton raises a short row to the button box', (
      tester,
    ) async {
      expect(
        await _rowHeight(tester, floor: AbRowContentFloor.iconButton),
        closeTo(AbTokens.iconButtonBox + _smPadding, 0.01),
      );
    });

    testWidgets('the floor is a floor, not a cap', (tester) async {
      final floored = await _rowHeight(
        tester,
        floor: AbRowContentFloor.iconButton,
        subtitle: true,
      );
      final natural = await _rowHeight(
        tester,
        floor: AbRowContentFloor.none,
        subtitle: true,
      );

      expect(natural, greaterThan(AbTokens.iconButtonBox + _smPadding));
      expect(floored, closeTo(natural, 0.01));
    });

    testWidgets('the floor tracks the text scaler', (tester) async {
      // A literal would be right at exactly one UI Size, which is why the
      // caller passes an enum and the row derives the value.
      final height = await _rowHeight(
        tester,
        floor: AbRowContentFloor.iconButton,
        scale: 1.3,
      );
      expect(height - _smPadding, closeTo(31.2, 0.01));
    });
  });

  testWidgets('onFocusChange reports the keyboard focus highlight', (
    tester,
  ) async {
    final reported = <bool>[];
    await pumpAntgrid(
      tester,
      SizedBox(
        width: 300,
        child: AbListRow(
          title: const Text('project-name'),
          onTap: () {},
          onFocusChange: reported.add,
        ),
      ),
    );
    final unfocused = tester.getSize(find.byType(AbListRow));

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();

    expect(reported, contains(true));
    // The callback is a report, not a style hook: a row that collapses its
    // actions needs the bit, and every row that ignores it must be untouched.
    expect(tester.getSize(find.byType(AbListRow)), unfocused);

    await pumpAntgrid(
      tester,
      SizedBox(
        width: 300,
        child: AbListRow(title: const Text('project-name'), onTap: () {}),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
