import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _link({
  VoidCallback? onPressed,
  bool inline = false,
  Widget? icon,
  CarbonLinkSize size = CarbonLinkSize.medium,
  String? semanticLabel,
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: CarbonLink(
    label: 'Docs',
    onPressed: onPressed,
    inline: inline,
    icon: icon,
    size: size,
    semanticLabel: semanticLabel,
  ),
);

TextStyle _style(WidgetTester tester) =>
    tester.widget<Text>(find.text('Docs')).style!;

void main() {
  final light = CarbonThemeData();

  testWidgets('a resting link is link-primary without an underline', (
    tester,
  ) async {
    await pumpCarbon(tester, _link(onPressed: () {}), theme: light);
    expect(_style(tester).color, light.colors.linkPrimary);
    expect(_style(tester).decoration, isNull);
  });

  testWidgets('hover underlines in link-primary-hover; press shows '
      'text-primary underlined', (tester) async {
    await pumpCarbon(tester, _link(onPressed: () {}), theme: light);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Docs')));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(_style(tester).color, light.colors.linkPrimaryHover);
    expect(_style(tester).decoration, TextDecoration.underline);
    await mouse.down(tester.getCenter(find.text('Docs')));
    await tester.pump();
    expect(_style(tester).color, light.colors.textPrimary);
    expect(_style(tester).decoration, TextDecoration.underline);
    await mouse.up();
  });

  testWidgets('keyboard focus draws a focus outline and underlines; Enter '
      'activates', (tester) async {
    var pressed = 0;
    await pumpCarbon(tester, _link(onPressed: () => pressed++), theme: light);
    await tester.tap(find.text('Docs'));
    expect(pressed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_style(tester).decoration, TextDecoration.underline);
    final outline = tester.widget<DecoratedBox>(
      find
          .ancestor(of: find.text('Docs'), matching: find.byType(DecoratedBox))
          .first,
    );
    expect(
      (outline.decoration as BoxDecoration).border,
      Border.all(color: light.colors.focus),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(pressed, 2);
  });

  testWidgets('inline links are always underlined', (tester) async {
    await pumpCarbon(
      tester,
      _link(onPressed: () {}, inline: true),
      theme: light,
    );
    expect(_style(tester).color, light.colors.linkPrimary);
    expect(_style(tester).decoration, TextDecoration.underline);
  });

  testWidgets('a disabled link is text-disabled, inert and not underlined '
      'unless inline', (tester) async {
    await pumpCarbon(tester, _link(), theme: light);
    expect(_style(tester).color, light.colors.textDisabled);
    expect(_style(tester).decoration, isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Docs')));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(_style(tester).color, light.colors.textDisabled);
    expect(_style(tester).decoration, isNull);
    await pumpCarbon(tester, _link(inline: true), theme: light);
    expect(_style(tester).color, light.colors.textDisabled);
    expect(_style(tester).decoration, TextDecoration.underline);
  });

  testWidgets('sizes use helper, control and a 16/22 large style', (
    tester,
  ) async {
    for (final (size, fontSize) in [
      (CarbonLinkSize.small, light.typography.helper.fontSize),
      (CarbonLinkSize.medium, light.typography.control.fontSize),
      (CarbonLinkSize.large, 16.0),
    ]) {
      await pumpCarbon(tester, _link(onPressed: () {}, size: size));
      expect(_style(tester).fontSize, fontSize);
    }
  });

  testWidgets('semantics: a named link, not a button', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _link(onPressed: () {}), theme: light);
    expect(
      tester.getSemantics(find.byType(CarbonInteraction)),
      matchesSemantics(
        label: 'Docs',
        isLink: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    await pumpCarbon(
      tester,
      _link(onPressed: () {}, semanticLabel: 'Open the docs'),
      theme: light,
    );
    expect(
      tester.getSemantics(find.byType(CarbonInteraction)).label,
      'Open the docs',
    );
    handle.dispose();
  });

  testWidgets('touch density gives a full-height target without moving the '
      'text', (tester) async {
    for (final target in [44.0, 48.0]) {
      await pumpCarbon(
        tester,
        _link(onPressed: () {}),
        theme: CarbonThemeData(
          density: CarbonDensity.touch,
          touchTarget: target,
        ),
      );
      final hit = tester.getRect(find.byType(CarbonInteraction));
      final text = tester.getRect(find.text('Docs'));
      expect(hit.height, target);
      expect(text.center.dy, closeTo(hit.center.dy, 0.5));
    }
  });

  testWidgets('a trailing icon follows the label in reading order', (
    tester,
  ) async {
    for (final dir in TextDirection.values) {
      await pumpCarbon(
        tester,
        _link(onPressed: () {}, icon: const CarbonIcon(CarbonIcons.launch)),
        theme: light,
        dir: dir,
      );
      final text = tester.getRect(find.text('Docs'));
      final icon = tester.getRect(find.byType(CarbonIcon));
      if (dir == TextDirection.ltr) {
        expect(icon.left, greaterThanOrEqualTo(text.right));
      } else {
        expect(icon.right, lessThanOrEqualTo(text.left));
      }
    }
  });
}
