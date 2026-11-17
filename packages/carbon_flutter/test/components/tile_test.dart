import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _tile({
  VoidCallback? onPressed,
  String? semanticLabel,
  Widget child = const Text('Overview'),
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(
    width: 240,
    child: CarbonClickableTile(
      onPressed: onPressed,
      semanticLabel: semanticLabel,
      child: child,
    ),
  ),
);

Color _fill(WidgetTester tester) => tester
    .widget<ColoredBox>(
      find
          .descendant(
            of: find.byType(CarbonClickableTile),
            matching: find.byType(ColoredBox),
          )
          .first,
    )
    .color;

void main() {
  final theme = CarbonThemeData();

  testWidgets('rests on the layer fill with 16 px padding', (tester) async {
    await pumpCarbon(tester, _tile(onPressed: () {}), theme: theme);
    expect(_fill(tester), theme.colors.layer01);
    final tile = tester.getRect(find.byType(CarbonClickableTile));
    final text = tester.getRect(find.text('Overview'));
    expect(text.left - tile.left, 16);
    expect(text.top - tile.top, 16);
  });

  testWidgets('steps up a layer inside a layered surface', (tester) async {
    await pumpCarbon(
      tester,
      CarbonLayer(level: 2, child: _tile(onPressed: () {})),
      theme: theme,
    );
    expect(_fill(tester), theme.colors.layer02);
  });

  testWidgets('hover and press change the fill', (tester) async {
    await pumpCarbon(tester, _tile(onPressed: () {}), theme: theme);
    final at = tester.getCenter(find.text('Overview'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: at);
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(_fill(tester), theme.colors.layerHover01);
    await mouse.down(at);
    await tester.pump();
    expect(_fill(tester), theme.colors.layerActive01);
    await mouse.up();
  });

  testWidgets('keyboard focus draws the 2 px focus outline inside the tile', (
    tester,
  ) async {
    await pumpCarbon(tester, _tile(onPressed: () {}), theme: theme);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final ring = find.descendant(
      of: find.byType(CarbonClickableTile),
      matching: find.byType(CarbonFocusRing),
    );
    expect(tester.widget<CarbonFocusRing>(ring).visible, isTrue);
    final box = tester.renderObject<RenderBox>(ring);
    expect(
      box,
      // The tile's layer fill is the first rect this box paints; the ring
      // is stroked over it.
      paints
        ..rect()
        ..rect(
        // The stroke is centred on its path, so the ring is inset by half its
        // width to stay inside the tile.
        rect: (Offset.zero & box.size).deflate(CarbonBorders.focus / 2),
        color: theme.colors.focus,
        strokeWidth: 2,
      ),
    );
  });

  testWidgets('tap, Enter and Space activate once each', (tester) async {
    var pressed = 0;
    await pumpCarbon(tester, _tile(onPressed: () => pressed++), theme: theme);
    await tester.tap(find.text('Overview'));
    expect(pressed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(pressed, 2);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(pressed, 3);
  });

  testWidgets('disabled is inert, unfocusable and announced disabled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _tile(), theme: theme);
    await tester.tap(find.text('Overview'), warnIfMissed: false);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_fill(tester), theme.colors.layer01);
    expect(
      tester
          .widget<DefaultTextStyle>(
            find
                .descendant(
                  of: find.byType(CarbonClickableTile),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style
          .color,
      theme.colors.textDisabled,
    );
    expect(
      tester.getSemantics(find.byType(CarbonInteraction)),
      matchesSemantics(
        label: 'Overview',
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('semantics: a button named by its text or by semanticLabel', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _tile(onPressed: () {}), theme: theme);
    expect(
      tester.getSemantics(find.byType(CarbonInteraction)).label,
      'Overview',
    );
    await pumpCarbon(
      tester,
      _tile(onPressed: () {}, semanticLabel: 'Open overview'),
      theme: theme,
    );
    expect(
      tester.getSemantics(find.byType(CarbonInteraction)),
      matchesSemantics(
        label: 'Open overview',
        isButton: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('compact is at least 40 tall; touch at least the touch target', (
    tester,
  ) async {
    await pumpCarbon(tester, _tile(onPressed: () {}), theme: theme);
    expect(
      tester.getSize(find.byType(CarbonClickableTile)).height,
      greaterThanOrEqualTo(40),
    );
    for (final target in [44.0, 48.0]) {
      await pumpCarbon(
        tester,
        _tile(onPressed: () {}),
        theme: CarbonThemeData(
          density: CarbonDensity.touch,
          touchTarget: target,
        ),
      );
      expect(
        tester.getSize(find.byType(CarbonClickableTile)).height,
        greaterThanOrEqualTo(target),
      );
    }
  });

  testWidgets('the 20 px arrow sits 12 px from the bottom end corner and text '
      'stays clear of it', (tester) async {
    await pumpCarbon(
      tester,
      _tile(
        onPressed: () {},
        child: const Text('A long label that wraps across several lines here'),
      ),
      theme: theme,
    );
    final tile = tester.getRect(find.byType(CarbonClickableTile));
    final arrow = tester.getRect(find.byType(CarbonIcon));
    expect(arrow.size, const Size(20, 20));
    expect(tile.right - arrow.right, 12);
    expect(tile.bottom - arrow.bottom, 12);
    expect(
      tester.widget<CarbonIcon>(find.byType(CarbonIcon)).color,
      theme.colors.iconInteractive,
    );
    expect(
      tester.getRect(find.byType(Text)).right,
      lessThanOrEqualTo(arrow.left),
    );
  });
}
