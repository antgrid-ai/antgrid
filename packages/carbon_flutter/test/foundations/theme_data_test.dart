import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CarbonThemeData equality and copyWith', () {
    test('equal inputs are equal and hash alike', () {
      final a = CarbonThemeData(scheme: CarbonThemeScheme.gray90);
      final b = CarbonThemeData(scheme: CarbonThemeScheme.gray90);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.copyWith(density: CarbonDensity.touch)));
      expect(a, isNot(CarbonThemeData(scheme: CarbonThemeScheme.gray100)));
    });

    test('defaults are White and compact', () {
      final theme = CarbonThemeData();
      expect(theme.scheme, CarbonThemeScheme.white);
      expect(theme.density, CarbonDensity.compact);
      expect(theme.colors, CarbonColors.white);
      expect(theme.brightness, Brightness.light);
    });

    test('forBrightness picks White or Gray 100', () {
      expect(
        CarbonThemeData.forBrightness(Brightness.dark).scheme,
        CarbonThemeScheme.gray100,
      );
      expect(
        CarbonThemeData.forBrightness(Brightness.light).scheme,
        CarbonThemeScheme.white,
      );
    });

    test('switching scheme takes that scheme palette and brightness', () {
      final next = CarbonThemeData().copyWith(scheme: CarbonThemeScheme.gray90);
      expect(next.colors, CarbonColors.gray90);
      expect(next.brightness, Brightness.dark);
    });

    test('custom colors carry over density and font changes', () {
      final custom = CarbonColors.white.copyWith(
        interactive: const Color(0xFF007D79),
      );
      final theme = CarbonThemeData(colors: custom);
      final touched = theme.copyWith(density: CarbonDensity.touch);
      expect(touched.colors, same(custom));
      expect(touched.colors.interactive, const Color(0xFF007D79));
      expect(
        theme.copyWith(fonts: const CarbonFonts(sans: 'Other')).colors,
        custom,
      );
    });

    test('explicit colors win over a scheme switch', () {
      final custom = CarbonColors.gray10.copyWith(
        interactive: const Color(0xFF007D79),
      );
      final next = CarbonThemeData().copyWith(
        scheme: CarbonThemeScheme.gray90,
        colors: custom,
      );
      expect(next.colors, custom);
      expect(next.scheme, CarbonThemeScheme.gray90);
    });

    test('CarbonColors equality is value based', () {
      expect(CarbonColors.white, CarbonColors.white.copyWith());
      expect(
        CarbonColors.white,
        isNot(CarbonColors.white.copyWith(focus: const Color(0xFF000000))),
      );
    });
  });

  group('density metrics', () {
    test('compact', () {
      final t = CarbonThemeData();
      expect(t.isTouch, isFalse);
      expect(t.controlHeight, 32);
      expect(t.smallControlHeight, 24);
      expect(t.largeControlHeight, 48);
      expect(t.minTarget, 32);
      expect(t.iconSize, 16);
      expect(t.controlPaddingX, 12);
    });

    test('touch keeps a 48px floor everywhere', () {
      final t = CarbonThemeData(density: CarbonDensity.touch);
      expect(t.isTouch, isTrue);
      expect(t.controlHeight, 48);
      expect(t.smallControlHeight, 48);
      expect(t.largeControlHeight, 64);
      expect(t.minTarget, 48);
      expect(t.iconSize, 20);
      expect(t.controlPaddingX, 16);
    });

    test('typography follows density', () {
      final compact = CarbonThemeData().typography;
      final touch = CarbonThemeData(density: CarbonDensity.touch).typography;
      expect(compact.control.fontSize, 14);
      expect(touch.control.fontSize, 16);
      expect(compact.label.fontSize, 12);
      expect(touch.label.fontSize, 14);
      expect(compact.helper.fontSize, 12);
      expect(touch.helper.fontSize, 14);
      expect(compact.body.fontSize, 14);
      expect(touch.body.fontSize, 16);
      expect(compact.code.fontSize, 12);
      expect(touch.code.fontSize, 14);
    });

    test('a density switch never keeps the previous metrics', () {
      final compact = CarbonThemeData();
      final touch = compact.copyWith(density: CarbonDensity.touch);
      final back = touch.copyWith(density: CarbonDensity.compact);
      expect(touch.typography.control.fontSize, 16);
      expect(back.typography, compact.typography);
    });

    test('line height is size-relative and roles never inherit', () {
      final type = CarbonThemeData().typography;
      for (final style in [
        type.label,
        type.helper,
        type.control,
        type.body,
        type.heading,
        type.headingLarge,
        type.title,
        type.code,
      ]) {
        expect(style.inherit, isFalse);
        expect(style.height, isNotNull);
        expect(style.fontWeight, isNotNull);
        expect(style.letterSpacing, isNotNull);
      }
      expect(type.control.height! * type.control.fontSize!, closeTo(18, 1e-9));
    });
  });

  group('typography families', () {
    test('sans roles resolve to the package-qualified Plex Sans', () {
      final type = CarbonThemeData().typography;
      for (final style in [
        type.label,
        type.helper,
        type.control,
        type.body,
        type.heading,
        type.headingLarge,
        type.title,
      ]) {
        expect(style.fontFamily, 'packages/carbon_flutter/IBM Plex Sans');
      }
    });

    test('code resolves to the package-qualified Plex Mono', () {
      expect(
        CarbonThemeData().typography.code.fontFamily,
        'packages/carbon_flutter/IBM Plex Mono',
      );
      expect(CarbonTypography.sansFamily, 'IBM Plex Sans');
      expect(CarbonTypography.package, 'carbon_flutter');
    });

    test('substituted fonts without a package use the bare family', () {
      final type = CarbonThemeData(
        fonts: const CarbonFonts(sans: 'Inter', mono: 'Fira Code', package: null),
      ).typography;
      expect(type.control.fontFamily, 'Inter');
      expect(type.code.fontFamily, 'Fira Code');
    });

    test('explicit typography overrides win', () {
      final custom = CarbonThemeData().typography.copyWith(
        control: const TextStyle(inherit: false, fontSize: 99),
      );
      final theme = CarbonThemeData(compactTypography: custom);
      expect(theme.typography.control.fontSize, 99);
      expect(
        theme.copyWith(density: CarbonDensity.touch).typography.control.fontSize,
        16,
      );
    });
  });

  group('layer helpers clamp', () {
    final t = CarbonThemeData();
    final c = t.colors;

    test('layer, hover, active, selected and selected-hover', () {
      expect(t.layer(-4), c.background);
      expect(t.layer(0), c.background);
      expect(t.layer(1), c.layer01);
      expect(t.layer(2), c.layer02);
      expect(t.layer(3), c.layer03);
      expect(t.layer(9), c.layer03);
      expect(t.layerHover(0), c.backgroundHover);
      expect(t.layerHover(7), c.layerHover03);
      expect(t.layerActive(0), c.backgroundActive);
      expect(t.layerActive(2), c.layerActive02);
      expect(t.layerSelected(0), c.backgroundSelected);
      expect(t.layerSelected(3), c.layerSelected03);
      expect(t.layerSelectedHover(0), c.backgroundSelectedHover);
      expect(t.layerSelectedHover(8), c.layerSelectedHover03);
    });

    test('field, accent and strong border start at level 1', () {
      expect(t.field(0), c.field01);
      expect(t.field(2), c.field02);
      expect(t.field(5), c.field03);
      expect(t.fieldHover(-1), c.fieldHover01);
      expect(t.fieldHover(3), c.fieldHover03);
      expect(t.layerAccent(0), c.layerAccent01);
      expect(t.layerAccent(4), c.layerAccent03);
      expect(t.borderStrong(0), c.borderStrong01);
      expect(t.borderStrong(2), c.borderStrong02);
      expect(t.borderStrong(9), c.borderStrong03);
    });

    test('subtle border includes the level-0 token', () {
      expect(t.borderSubtle(-1), c.borderSubtle00);
      expect(t.borderSubtle(0), c.borderSubtle00);
      expect(t.borderSubtle(1), c.borderSubtle01);
      expect(t.borderSubtle(9), c.borderSubtle03);
    });
  });
}
