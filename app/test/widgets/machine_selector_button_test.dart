import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/widgets/machine_selector_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _machines = {'local': 'Local machine', 'm1': 'Laptop'};

Future<void> _pump(
  WidgetTester tester, {
  Map<String, String> machines = _machines,
  String currentId = 'm1',
  String name = 'Laptop',
  ValueChanged<String>? onPicked,
}) => tester.pumpWidget(
  MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildAbTheme(),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: MachineSelectorButton(
          machines: machines,
          currentId: currentId,
          name: name,
          connected: true,
          wide: false,
          onPicked: onPicked ?? (_) {},
        ),
      ),
    ),
  ),
);

Future<void> _openMenu(WidgetTester tester, String name) async {
  await tester.tap(find.widgetWithText(AbButton, name));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('menu lists every machine with a check on the current one', (
    tester,
  ) async {
    await _pump(tester);
    await _openMenu(tester, 'Laptop');

    expect(find.text('Local machine'), findsOneWidget);
    expect(find.text('Laptop'), findsWidgets);
    final checks = find.byWidgetPredicate(
      (w) => w is AbIcon && w.icon == AbIcons.check,
    );
    expect(checks, findsOneWidget);
    final row = find.ancestor(of: checks, matching: find.byType(Row)).first;
    expect(
      find.descendant(of: row, matching: find.text('Laptop')),
      findsOneWidget,
    );
  });

  testWidgets('picking a row reports its id', (tester) async {
    final picked = <String>[];
    await _pump(tester, onPicked: picked.add);
    await _openMenu(tester, 'Laptop');
    await tester.tap(find.text('Local machine'));
    await tester.pumpAndSettle();

    expect(picked, ['local']);
  });

  testWidgets('dismissing the menu reports nothing', (tester) async {
    final picked = <String>[];
    await _pump(tester, onPicked: picked.add);
    await _openMenu(tester, 'Laptop');
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();

    expect(find.text('Local machine'), findsNothing);
    expect(picked, isEmpty);
  });

  testWidgets('semantics label names the machine', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);

    expect(find.bySemanticsLabel('Machine: Laptop, change'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a long name ellipsizes within the compact width', (
    tester,
  ) async {
    final name = 'N' * 60;
    await _pump(
      tester,
      machines: {'m1': name},
      currentId: 'm1',
      name: name,
    );

    expect(tester.takeException(), isNull);
    final width = tester.getSize(find.byType(MachineSelectorButton)).width;
    expect(width, lessThanOrEqualTo(AbTokens.space24 * 6));
  });
}
