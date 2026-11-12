import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' show MaterialScrollBehavior, Scrollbar, Theme;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/host_theme.dart';

const _long =
    'A very long label that cannot possibly fit in the menu width and so is '
    'truncated with an ellipsis and a tooltip';

Widget _at(Widget child) => Align(
  alignment: AlignmentDirectional.topStart,
  child: Padding(padding: const EdgeInsets.all(40), child: child),
);

List<CarbonMenuEntry> _entries() => <CarbonMenuEntry>[
  CarbonMenuItem(label: 'Rename', onPressed: () {}),
  CarbonMenuItem(
    label: 'Delete',
    onPressed: () {},
    kind: CarbonMenuItemKind.danger,
  ),
];

Color _rowFill(WidgetTester tester, String label) {
  final box = find
      .ancestor(of: find.text(label), matching: find.byType(ColoredBox))
      .first;
  return tester.widget<ColoredBox>(box).color;
}

// Visible fills the trigger's button paints itself. A ghost button is clear
// at rest, so any entry is hover or press feedback.
List<Color> _buttonFills(WidgetTester tester) => find
    .descendant(
      of: find.byType(CarbonButton),
      matching: find.byType(DecoratedBox),
    )
    .evaluate()
    .map((e) => (e.widget as DecoratedBox).decoration)
    .whereType<BoxDecoration>()
    .map((d) => d.color)
    .whereType<Color>()
    .where((c) => c.a > 0)
    .toList();

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets('an open overflow trigger shows no hover or press fill over its layer', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      underHostileHost(_at(CarbonOverflowMenu(entries: _entries()))),
      size: const Size(800, 600),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    final trigger = find.byType(CarbonButton);
    await mouse.moveTo(tester.getCenter(trigger));
    await tester.pump();
    expect(_buttonFills(tester), isNotEmpty, reason: 'closed + hover');
    await tester.tap(trigger);
    await _settle(tester);
    await mouse.moveTo(tester.getCenter(trigger));
    await tester.pump();
    expect(_buttonFills(tester), isEmpty, reason: 'open + hover');
    await mouse.down(tester.getCenter(trigger));
    await _settle(tester);
    expect(_buttonFills(tester), isEmpty, reason: 'open + pressed');
    await mouse.up();
    await _settle(tester);
  });

  testWidgets('a truncated menu row shows its pressed fill at touch down', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      underHostileHost(
        _at(
          CarbonMenuButton(
            label: 'Go',
            entries: <CarbonMenuEntry>[
              CarbonMenuItem(label: _long, onPressed: () {}),
            ],
          ),
        ),
      ),
      size: const Size(800, 600),
    );
    await tester.tap(find.text('Go'));
    await _settle(tester);
    final before = _rowFill(tester, _long);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text(_long)),
    );
    await tester.pump();
    expect(_rowFill(tester, _long), isNot(before));
    await gesture.up();
    await _settle(tester);
  });

  testWidgets('an icon-only trigger shows its pressed fill at mouse down', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      underHostileHost(_at(CarbonOverflowMenu(entries: _entries()))),
      size: const Size(800, 600),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    final center = tester.getCenter(find.byType(CarbonButton));
    await mouse.moveTo(center);
    await tester.pump();
    final hover = find
        .descendant(
          of: find.byType(CarbonButton),
          matching: find.byType(DecoratedBox),
        )
        .evaluate()
        .map((e) => (e.widget as DecoratedBox).decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .whereType<Color>()
        .toList();
    await mouse.down(center);
    await tester.pump();
    final pressed = find
        .descendant(
          of: find.byType(CarbonButton),
          matching: find.byType(DecoratedBox),
        )
        .evaluate()
        .map((e) => (e.widget as DecoratedBox).decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .whereType<Color>()
        .toList();
    expect(pressed, isNot(hover));
    await mouse.up();
    await _settle(tester);
  });

  testWidgets('a long touch press still opens a tooltip', (tester) async {
    await pumpCarbon(
      tester,
      _at(
        const CarbonTooltip(
          message: 'Hint text',
          child: SizedBox(width: 80, height: 32),
        ),
      ),
      size: const Size(800, 600),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SizedBox).last),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Hint text'), findsOneWidget);
    await gesture.up();
    await _settle(tester);
  });

  testWidgets('dragging a touch away before the long press shows no tooltip', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _at(
        const CarbonTooltip(
          message: 'Hint text',
          child: SizedBox(width: 80, height: 32),
        ),
      ),
      size: const Size(800, 600),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(SizedBox).last),
    );
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Hint text'), findsNothing);
    await gesture.up();
    await _settle(tester);
  });

  testWidgets('a touch press on a danger row paints the danger fill', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      underHostileHost(_at(CarbonMenuButton(label: 'Go', entries: _entries()))),
      size: const Size(800, 600),
    );
    await tester.tap(find.text('Go'));
    await _settle(tester);
    final colors = CarbonTheme.of(tester.element(find.text('Delete'))).colors;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Delete')),
    );
    await tester.pump();
    expect(_rowFill(tester, 'Delete'), colors.buttonDangerPrimary);
    await gesture.up();
    await _settle(tester);
  });

  testWidgets('a tall menu draws no host scrollbar', (tester) async {
    await pumpCarbon(
      tester,
      Theme(
        data: hostileHostTheme.copyWith(platform: TargetPlatform.windows),
        child: ScrollConfiguration(
          behavior: const MaterialScrollBehavior(),
          child: _at(
            CarbonMenuButton(
              label: 'Go',
              entries: <CarbonMenuEntry>[
                for (var i = 0; i < 40; i++)
                  CarbonMenuItem(label: 'Item $i', onPressed: () {}),
              ],
            ),
          ),
        ),
      ),
      size: const Size(800, 500),
    );
    await tester.tap(find.text('Go'));
    await _settle(tester);
    expect(
      find.descendant(
        of: find.byType(SingleChildScrollView),
        matching: find.byType(Scrollbar),
      ),
      findsNothing,
    );
  });
}
