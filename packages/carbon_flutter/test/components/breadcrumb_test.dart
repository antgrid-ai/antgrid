import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

Widget _crumbs({
  VoidCallback? onHome,
  bool trailingSlash = true,
  double width = 400,
}) => Align(
  alignment: AlignmentDirectional.topStart,
  child: SizedBox(
    width: width,
    child: CarbonBreadcrumb(
      trailingSlash: trailingSlash,
      items: [
        CarbonBreadcrumbItem(label: 'Home', onPressed: onHome ?? () {}),
        const CarbonBreadcrumbItem(label: 'Current'),
      ],
    ),
  ),
);

TextStyle _style(WidgetTester tester, String label) =>
    tester.widget<Text>(find.text(label)).style!;

void main() {
  final light = CarbonThemeData();

  testWidgets('a link is link-primary and the current page text-primary', (
    tester,
  ) async {
    await pumpCarbon(tester, _crumbs(), theme: light);
    expect(_style(tester, 'Home').color, light.colors.linkPrimary);
    expect(_style(tester, 'Home').decoration, isNull);
    expect(_style(tester, 'Current').color, light.colors.textPrimary);
    expect(
      find.byType(CarbonInteraction),
      findsOneWidget,
      reason: 'the current page is not a link',
    );
  });

  testWidgets('every step is followed by a slash unless trailingSlash is off', (
    tester,
  ) async {
    await pumpCarbon(tester, _crumbs(), theme: light);
    expect(find.text('/'), findsNWidgets(2));
    await pumpCarbon(tester, _crumbs(trailingSlash: false), theme: light);
    expect(find.text('/'), findsOneWidget);
    expect(
      tester.getRect(find.text('/')).left,
      greaterThan(tester.getRect(find.text('Home')).right),
    );
    expect(
      tester.getRect(find.text('Current')).left,
      greaterThan(tester.getRect(find.text('/')).right),
    );
  });

  testWidgets('hover underlines in link-primary-hover; press shows '
      'text-primary', (tester) async {
    await pumpCarbon(tester, _crumbs(), theme: light);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('Home')));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(_style(tester, 'Home').color, light.colors.linkPrimaryHover);
    expect(_style(tester, 'Home').decoration, TextDecoration.underline);
    await mouse.down(tester.getCenter(find.text('Home')));
    await tester.pump();
    expect(_style(tester, 'Home').color, light.colors.textPrimary);
    await mouse.up();
  });

  testWidgets('tap and Enter activate a link', (tester) async {
    var pressed = 0;
    await pumpCarbon(tester, _crumbs(onHome: () => pressed++), theme: light);
    await tester.tap(find.text('Home'));
    expect(pressed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(_style(tester, 'Home').decoration, TextDecoration.underline);
    final outline = tester.widget<DecoratedBox>(
      find
          .ancestor(of: find.text('Home'), matching: find.byType(DecoratedBox))
          .first,
    );
    expect(
      (outline.decoration as BoxDecoration).border,
      Border.all(color: light.colors.focus),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(pressed, 2);
  });

  testWidgets('a link is a named link in semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await pumpCarbon(tester, _crumbs(), theme: light);
    expect(
      tester.getSemantics(find.byType(CarbonInteraction)),
      matchesSemantics(
        label: 'Home',
        isLink: true,
        isFocusable: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('touch density gives a link a full-height target without '
      'moving its text', (tester) async {
    for (final target in [44.0, 48.0]) {
      await pumpCarbon(
        tester,
        _crumbs(),
        theme: CarbonThemeData(
          density: CarbonDensity.touch,
          touchTarget: target,
        ),
      );
      final hit = tester.getRect(find.byType(CarbonInteraction));
      final text = tester.getRect(find.text('Home'));
      expect(hit.height, target);
      expect(text.center.dy, closeTo(hit.center.dy, 0.5));
      expect(
        tester.getRect(find.text('Current')).center.dy,
        closeTo(text.center.dy, 0.5),
      );
    }
  });

  testWidgets('steps wrap rather than overflow in a narrow box', (
    tester,
  ) async {
    await pumpCarbon(
      tester,
      _crumbs(width: 120),
      theme: light,
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.text('Current')).top,
      greaterThan(tester.getRect(find.text('Home')).top),
    );
  });
}
