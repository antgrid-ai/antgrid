import 'dart:ui' show Tristate;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void _noop() {}

Widget _action(String label, VoidCallback onPressed) => CarbonButton.iconOnly(
  icon: const CarbonIcon(CarbonIcons.trashCan),
  semanticLabel: label,
  onPressed: onPressed,
);

bool _holdsFocus(WidgetTester tester, Finder f) {
  final focus = FocusManager.instance.primaryFocus?.context;
  if (focus == null) return false;
  final target = tester.element(f);
  var found = false;
  focus.visitAncestorElements((e) {
    if (identical(e, target)) found = true;
    return !found;
  });
  return found;
}

void main() {
  testWidgets('a touch tap on hidden actions does not run them', (
    tester,
  ) async {
    var deleted = 0;
    var tapped = 0;
    await pumpCarbon(
      tester,
      CarbonContainedList(
        label: 'Files',
        children: [
          CarbonContainedListRow(
            title: 'one',
            onPressed: () => tapped++,
            revealActionsOnHover: true,
            actions: [_action('Delete', () => deleted++)],
          ),
        ],
      ),
    );
    await tester.tapAt(tester.getCenter(find.byType(CarbonButton)));
    await tester.pump();
    expect(deleted, 0);
    expect(tapped, 0);
  });

  testWidgets('keyboard focus reaches hover-revealed actions of a static row', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      Column(
        children: [
          const CarbonButton(label: 'Before', onPressed: _noop),
          CarbonContainedList(
            label: 'Files',
            children: [
              CarbonContainedListRow(
                title: 'static',
                revealActionsOnHover: true,
                actions: [_action('Delete', _noop)],
              ),
            ],
          ),
          const CarbonButton(label: 'After', onPressed: _noop),
        ],
      ),
    );
    final action = find.byWidgetPredicate(
      (w) => w is CarbonButton && w.semanticLabel == 'Delete',
    );
    Focus.of(tester.element(find.text('Before'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_holdsFocus(tester, action), isTrue);
  });

  testWidgets('single-selection rows all announce a selected state', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(
      tester,
      CarbonContainedList(
        label: 'Env',
        children: [
          CarbonContainedListRow(title: 'A', onPressed: _noop, selected: false),
          CarbonContainedListRow(title: 'B', onPressed: _noop, selected: true),
        ],
      ),
    );
    final a = tester.getSemantics(find.text('A')).flagsCollection;
    final b = tester.getSemantics(find.text('B')).flagsCollection;
    expect(a.isSelected, Tristate.isFalse);
    expect(b.isSelected, Tristate.isTrue);
    expect(a.isButton, b.isButton);
    expect(a.isEnabled, Tristate.isTrue);
    handle.dispose();
  });
}
