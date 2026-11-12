import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

// Pointer state the shared interaction primitive owns. A tap is recognised
// anywhere within the touch slop of the press, but Carbon's controls are
// buttons, which click only when released over themselves. And CSS :hover
// follows the pointer, so a control re-enabled under a resting pointer is
// hovered without the pointer moving.

Future<List<String>> _openMenu(WidgetTester tester) async {
  final fired = <String>[];
  final controller = CarbonPopupController();
  addTearDown(controller.dispose);
  await pumpCarbon(
    tester,
    Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: CarbonMenu(
          controller: controller,
          entries: [
            CarbonMenuItem(label: 'Rename', onPressed: () => fired.add('Rename')),
            CarbonMenuItem(label: 'Remove', onPressed: () => fired.add('Remove')),
          ],
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
    ),
  );
  controller.open();
  await tester.pumpAndSettle();
  return fired;
}

Rect _row(WidgetTester tester, String label) => tester.getRect(
  find.ancestor(of: find.text(label), matching: find.byType(CarbonInteraction)).first,
);

void main() {
  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('a press dragged onto the next menu row activates neither '
        '(${kind.name})', (tester) async {
      final fired = await _openMenu(tester);
      final rename = _row(tester, 'Rename');
      final remove = _row(tester, 'Remove');
      final press = await tester.startGesture(
        Offset(rename.center.dx, rename.bottom - 3),
        kind: kind,
      );
      await tester.pump();
      await press.moveTo(Offset(remove.center.dx, remove.top + 3));
      await tester.pump();
      await press.up();
      await tester.pumpAndSettle();
      expect(fired, isEmpty);
    });

    testWidgets('a press that wobbles but stays on the row activates it '
        '(${kind.name})', (tester) async {
      final fired = await _openMenu(tester);
      final rename = _row(tester, 'Rename');
      final press = await tester.startGesture(rename.center, kind: kind);
      await tester.pump();
      await press.moveTo(rename.center + const Offset(4, 3));
      await tester.pump();
      await press.up();
      await tester.pumpAndSettle();
      expect(fired, ['Rename']);
    });
  }

  testWidgets('a press dragged off a button does not press it', (
    tester,
  ) async {
    var pressed = 0;
    await pumpCarbon(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: CarbonButton(label: 'Save', onPressed: () => pressed++),
        ),
      ),
    );
    final button = tester.getRect(find.byType(CarbonButton));
    final press = await tester.startGesture(
      Offset(button.right - 2, button.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await press.moveTo(Offset(button.right + 6, button.center.dy));
    await tester.pump();
    await press.up();
    await tester.pump();
    expect(pressed, 0);
  });

  testWidgets('a field action re-enabled under a resting pointer shows its '
      'hover fill', (tester) async {
    var enabled = true;
    late StateSetter setOuter;
    await pumpCarbon(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: StatefulBuilder(
          builder: (context, setState) {
            setOuter = setState;
            return CarbonFieldAction(
              icon: const CarbonIcon(CarbonIcons.view),
              semanticLabel: 'Show password',
              onPressed: enabled ? () {} : null,
            );
          },
        ),
      ),
    );
    Color fill() => tester
        .widget<ColoredBox>(
          find.descendant(
            of: find.byType(CarbonFieldAction),
            matching: find.byType(ColoredBox),
          ),
        )
        .color;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(
      location: tester.getCenter(find.byType(CarbonFieldAction)),
    );
    await tester.pump();
    final hover = fill();
    expect(hover.a, greaterThan(0));
    setOuter(() => enabled = false);
    await tester.pump();
    expect(fill().a, 0);
    setOuter(() => enabled = true);
    await tester.pump();
    await tester.pump();
    expect(fill(), hover);
  });

  testWidgets('a long touch press on an icon-only button shows its tooltip '
      'and does not press it', (tester) async {
    var pressed = 0;
    await pumpCarbon(
      tester,
      Align(
        alignment: Alignment.center,
        child: CarbonButton.iconOnly(
          icon: const CarbonIcon(CarbonIcons.trashCan),
          semanticLabel: 'Delete',
          onPressed: () => pressed++,
        ),
      ),
      size: const Size(800, 600),
    );
    final press = await tester.startGesture(
      tester.getCenter(find.byType(CarbonButton)),
    );
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Delete'), findsOneWidget);
    await press.up();
    await tester.pump();
    expect(pressed, 0);
    // A short tap still presses it.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CarbonButton));
    await tester.pumpAndSettle();
    expect(pressed, 1);
  });

  // A press focuses a tab, and focus reveals a half-visible tab. The reveal
  // must not slide the tab out from under a held pointer, or the release
  // lands off it and the selection is lost.
  testWidgets('a held press on a half-visible tab still selects it', (
    tester,
  ) async {
    String? selected;
    await pumpCarbon(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: CarbonTabs<String>(
            tabs: [
              for (var i = 0; i < 8; i++)
                CarbonOption(value: 't$i', label: 'Tab $i'),
            ],
            value: 't0',
            onChanged: (v) => selected = v,
          ),
        ),
      ),
      size: const Size(800, 600),
    );
    // The first tab that runs past the strip's end edge.
    final strip = tester.getRect(find.byType(CarbonTabs<String>));
    final label = [
      for (var i = 0; i < 8; i++) 'Tab $i',
    ].firstWhere((l) => tester.getRect(find.text(l)).right > strip.right - 40);
    final at = Offset(strip.right - 50, tester.getCenter(find.text(label)).dy);
    final hit = [
      for (var i = 0; i < 8; i++) 'Tab $i',
    ].firstWhere((l) {
      final r = tester.getRect(
        find.ancestor(of: find.text(l), matching: find.byType(CarbonInteraction))
            .first,
      );
      return r.contains(at);
    });
    final press = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 400));
    await press.up();
    await tester.pumpAndSettle();
    expect(selected, 't${hit.split(' ').last}');
  });
}
