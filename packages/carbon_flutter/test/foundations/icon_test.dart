import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {TextDirection direction = TextDirection.ltr}) =>
    Directionality(
      textDirection: direction,
      child: Center(child: CarbonTheme(data: CarbonThemeData(), child: child)),
    );

RenderObject _painter(WidgetTester tester) => tester.renderObject(
  find.descendant(
    of: find.byType(CarbonIcon),
    matching: find.byType(CustomPaint),
  ),
);

void main() {
  group('semantics', () {
    testWidgets('decorative icons are excluded from the tree', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const CarbonIcon(CarbonIcons.close)));
      final root = tester.renderObject(find.byType(CarbonIcon)).owner!.semanticsOwner!.rootSemanticsNode!;
      var count = 0;
      root.visitChildren((_) {
        count++;
        return true;
      });
      expect(count, 0);
      handle.dispose();
    });

    testWidgets('a labelled icon is announced as an image', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(const CarbonIcon(CarbonIcons.warning, semanticLabel: 'Warning')),
      );
      expect(
        tester.getSemantics(find.byType(CarbonIcon)),
        matchesSemantics(label: 'Warning', isImage: true),
      );
      handle.dispose();
    });
  });

  group('sizing and color', () {
    testWidgets('defaults to the density icon size', (tester) async {
      await tester.pumpWidget(_host(const CarbonIcon(CarbonIcons.add)));
      expect(tester.getSize(find.byType(CustomPaint).last), const Size(16, 16));
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: CarbonTheme(
            data: CarbonThemeData(density: CarbonDensity.touch),
            child: const Center(child: CarbonIcon(CarbonIcons.add)),
          ),
        ),
      );
      expect(tester.getSize(find.byType(CustomPaint).last), const Size(20, 20));
    });

    testWidgets('explicit size and color are painted', (tester) async {
      const color = Color(0xFF123456);
      await tester.pumpWidget(
        _host(const CarbonIcon(CarbonIcons.add, size: 24, color: color)),
      );
      expect(tester.getSize(find.byType(CustomPaint).last), const Size(24, 24));
      expect(_painter(tester), paints..path(color: color));
    });

    testWidgets('default color is iconPrimary', (tester) async {
      await tester.pumpWidget(_host(const CarbonIcon(CarbonIcons.add)));
      expect(
        _painter(tester),
        paints..path(color: CarbonColors.white.iconPrimary),
      );
    });
  });

  group('RTL mirroring', () {
    testWidgets('chevronRight flips horizontally in RTL', (tester) async {
      expect(CarbonIcons.chevronRight.mirrorsInRtl, isTrue);
      await tester.pumpWidget(
        _host(
          const CarbonIcon(CarbonIcons.chevronRight),
          direction: TextDirection.rtl,
        ),
      );
      expect(
        _painter(tester),
        paints
          ..translate(x: 16.0, y: 0.0)
          ..scale(x: -1.0, y: 1.0)
          ..path(),
      );
    });

    testWidgets('chevronRight is untouched in LTR', (tester) async {
      await tester.pumpWidget(_host(const CarbonIcon(CarbonIcons.chevronRight)));
      expect(_painter(tester), isNot(paints..scale(x: -1.0, y: 1.0)));
      expect(_painter(tester), paints..path());
    });

    testWidgets('non-directional glyphs never mirror', (tester) async {
      expect(CarbonIcons.add.mirrorsInRtl, isFalse);
      await tester.pumpWidget(
        _host(const CarbonIcon(CarbonIcons.add), direction: TextDirection.rtl),
      );
      expect(_painter(tester), isNot(paints..scale(x: -1.0, y: 1.0)));
    });

    testWidgets('flipping direction repaints with the mirrored transform', (
      tester,
    ) async {
      await tester.pumpWidget(_host(const CarbonIcon(CarbonIcons.arrowRight)));
      expect(_painter(tester), isNot(paints..scale(x: -1.0, y: 1.0)));
      await tester.pumpWidget(
        _host(
          const CarbonIcon(CarbonIcons.arrowRight),
          direction: TextDirection.rtl,
        ),
      );
      expect(_painter(tester), paints..scale(x: -1.0, y: 1.0));
    });
  });

  test('every bundled glyph parses to a non-empty path', () {
    for (final icon in CarbonIcons.values) {
      // Constructing the widget is cheap; painting parses the path data.
      expect(const CarbonIcon(CarbonIcons.add).icon, CarbonIcons.add);
      expect(icon.name, isNotEmpty);
    }
    expect(carbonIconsVersion, '11.92.0');
  });
}
