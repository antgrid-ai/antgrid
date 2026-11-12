import 'dart:ui' as ui;

import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

// A frame drawn under full-width rows or segments loses its sides wherever a
// hovered or selected fill covers it. These tests read rendered pixels,
// because the decorations alone look correct in every such case.

const _opts = [
  CarbonOption(value: 'a', label: 'Alpha'),
  CarbonOption(value: 'b', label: 'Bravo'),
  CarbonOption(value: 'c', label: 'Charlie'),
];

final _g100 = CarbonThemeData.forBrightness(Brightness.dark);

/// The colours of one row of screen pixels from [x0] to [x1], exclusive,
/// popups included.
Future<List<Color>> _pixels(
  WidgetTester tester,
  double y,
  double x0,
  double x1,
) async {
  final view = tester.binding.renderViews.first;
  late List<Color> out;
  await tester.runAsync(() async {
    final image = await (view.debugLayer! as OffsetLayer).toImage(
      Offset.zero & view.size,
    );
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    out = <Color>[
      for (var x = x0.round(); x < x1.round(); x++)
        Color(
          (data.getUint32((y.round() * image.width + x) * 4) >> 8) |
              0xFF000000,
        ),
    ];
    image.dispose();
  });
  return out;
}

String _runs(List<Color> px) {
  final out = <String>[];
  for (var i = 0; i < px.length;) {
    var j = i;
    while (j < px.length && px[j] == px[i]) {
      j++;
    }
    out.add('${(px[i].toARGB32() & 0xFFFFFF).toRadixString(16)}x${j - i}');
    i = j;
  }
  return out.join(' ');
}

Future<TestGesture> _hover(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: at);
  addTearDown(mouse.removePointer);
  await tester.pump(const Duration(milliseconds: 300));
  return mouse;
}

/// One logical pixel per screen pixel, so a 1px rule is one sample.
void _unitPixels(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 600);
  addTearDown(tester.view.reset);
}

Widget _host(Widget child) => Align(
  alignment: Alignment.topLeft,
  child: Padding(
    padding: const EdgeInsets.all(40),
    child: SizedBox(width: 300, child: child),
  ),
);

void main() {
  testWidgets('an open list has no frame, and a hovered or selected row '
      'fills it edge to edge', (tester) async {
    _unitPixels(tester);
    await pumpCarbon(
      tester,
      _host(
        CarbonDropdown<String>(
          label: 'Agent',
          options: _opts,
          value: 'a',
          onChanged: (_) {},
        ),
      ),
      theme: _g100,
    );
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    final list = tester.getRect(find.byType(ListView));
    await _hover(tester, tester.getCenter(find.text('Bravo')));

    // Alpha is selected, Bravo hovered, Charlie at rest. Sampled 3px below
    // each row's top: inside the row, clear of its text.
    for (final label in ['Alpha', 'Bravo', 'Charlie']) {
      final row = tester.getRect(find.text(label).last);
      final px = await _pixels(tester, row.top - 4, list.left, list.right);
      expect(px.toSet(), hasLength(1), reason: '$label row: ${_runs(px)}');
    }
  });

  testWidgets('a hovered end segment keeps the switcher frame', (
    tester,
  ) async {
    _unitPixels(tester);
    await pumpCarbon(
      tester,
      _host(
        CarbonContentSwitcher<String>(
          options: _opts,
          value: 'a',
          onChanged: (_) {},
        ),
      ),
      theme: _g100,
    );
    final switcher = tester.getRect(find.byType(CarbonContentSwitcher<String>));
    await _hover(tester, tester.getCenter(find.text('Charlie')));
    final px = await _pixels(
      tester,
      switcher.center.dy,
      switcher.right - 3,
      switcher.right,
    );
    expect(px.last, _g100.colors.borderInverse, reason: '$px');
    expect(px.first, _g100.colors.layerHover01, reason: '$px');
  });

  testWidgets('a focused segment shows its whole focus ring over the frame', (
    tester,
  ) async {
    _unitPixels(tester);
    await pumpCarbon(
      tester,
      _host(
        CarbonContentSwitcher<String>(
          options: _opts,
          value: 'a',
          activation: CarbonActivationMode.manual,
          onChanged: (_) {},
        ),
      ),
      theme: _g100,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    final bravo = tester.getRect(
      find
          .ancestor(
            of: find.text('Bravo'),
            matching: find.byType(CarbonFocusRing),
          )
          .first,
    );
    final top = await _pixels(tester, bravo.top, bravo.left + 4, bravo.right - 4);
    expect(top.toSet(), {_g100.colors.focus}, reason: _runs(top));
  });

  testWidgets('a bordered menu keeps its frame beside a hovered row', (
    tester,
  ) async {
    _unitPixels(tester);
    final controller = CarbonPopupController();
    addTearDown(controller.dispose);
    await pumpCarbon(
      tester,
      _host(
        CarbonMenu(
          controller: controller,
          border: true,
          entries: [
            CarbonMenuItem(label: 'Rename', onPressed: () {}),
            CarbonMenuItem(label: 'Remove', onPressed: () {}),
          ],
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
      theme: _g100,
    );
    controller.open();
    await tester.pumpAndSettle();
    final framed = find.ancestor(
      of: find.text('Remove'),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border != null,
      ),
    );
    final panel = tester.getRect(framed.first);
    final decoration =
        tester.widget<DecoratedBox>(framed.first).decoration as BoxDecoration;
    final frame = (decoration.border! as Border).left.color;
    final row = tester.getRect(find.text('Remove'));
    await _hover(tester, row.center);
    final px = await _pixels(tester, row.top - 4, panel.left, panel.right);
    expect(px.first, frame, reason: _runs(px));
    expect(px.last, frame, reason: _runs(px));
    // The hover fill runs from just inside one side to just inside the other.
    expect(px.sublist(1, px.length - 1).toSet(), hasLength(1), reason: _runs(px));
    expect(px[1], isNot(frame), reason: _runs(px));
    expect(px[1], isNot(decoration.color), reason: _runs(px));
  });

  testWidgets('contained tabs draw no divider beside the selected tab', (
    tester,
  ) async {
    _unitPixels(tester);
    await pumpCarbon(
      tester,
      _host(
        CarbonTabs<String>(
          tabs: _opts,
          value: 'a',
          variant: CarbonTabsVariant.contained,
          onChanged: (_) {},
        ),
      ),
      theme: _g100,
    );
    Rect tab(String label) => tester.getRect(
      find
          .ancestor(of: find.text(label), matching: find.byType(DecoratedBox))
          .first,
    );
    final alpha = tab('Alpha');
    final bravo = tab('Bravo');
    final charlie = tab('Charlie');
    // Above the labels and below the selected tab's 2px top bar.
    final y = alpha.top + 6;
    for (final hovered in [false, true]) {
      if (hovered) await _hover(tester, bravo.center);
      final row = await _pixels(tester, y, alpha.left, charlie.right);
      // A rule is a column brighter than the fill 3px either side of it.
      // Tab edges fall between pixels, so a 1px rule can spread over two.
      final rules = <double>[
        for (var i = 3; i < row.length - 3; i++)
          if (row[i].r > row[i - 3].r + 8 / 255 &&
              row[i].r > row[i + 3].r + 8 / 255)
            alpha.left + i,
      ];
      expect(rules, isNotEmpty, reason: 'hovered: $hovered, ${_runs(row)}');
      for (final x in rules) {
        expect(
          (x - charlie.left).abs(),
          lessThanOrEqualTo(1),
          reason: 'hovered: $hovered, rule at $x: ${_runs(row)}',
        );
      }
    }
  });
}
