import 'dart:io';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// The asset path is the whole point of the `.icon()` variant, and it is not
  /// observable on [SvgPicture] itself — only on the loader it was built with.
  String assetOf(WidgetTester tester) {
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    return (svg.bytesLoader as SvgAssetLoader).assetName;
  }

  // MaterialApp lerps a theme change over 200ms by default, so without this
  // the frame right after a re-pump still carries the outgoing palette.
  Widget underPreset(AbThemePreset preset, Widget child) => MaterialApp(
    themeAnimationDuration: Duration.zero,
    theme: ThemeData(extensions: <ThemeExtension<dynamic>>[kPresets[preset]!]),
    home: child,
  );

  testWidgets('default renders the wordmark at 20px', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AbBrandMark()));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.height, 20);
    expect(assetOf(tester), 'assets/logo/antgrid-wordmark.svg');
  });

  testWidgets('.icon() renders the square mark at 18px', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AbBrandMark.icon()));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.height, 18);
    // Tileless specifically: the plated antgrid-mark.svg paints a #101418 tile
    // on the #09090B bar, which reads as elevation.
    expect(assetOf(tester), 'assets/logo/antgrid-mark-small.svg');
  });

  // The brand's reduction rule, applied by the widget so no caller has to know
  // it: four chevrons smear into each other below 40px.
  testWidgets('.icon() drops to the two-agent cut below 40px', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AbBrandMark.icon(height: 39)),
    );
    expect(assetOf(tester), 'assets/logo/antgrid-mark-small.svg');

    await tester.pumpWidget(
      const MaterialApp(home: AbBrandMark.icon(height: 40)),
    );
    expect(assetOf(tester), 'assets/logo/antgrid-mark-transparent.svg');
  });

  testWidgets('.icon() applies no colorFilter — the asset is two-tone', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AbBrandMark.icon()));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.colorFilter, isNull);
  });

  // The paper-ink cuts are invisible on the shipped light preset, so every cut
  // has to flip. Asserted per cut because each is a separate asset pair.
  for (final (name, widget) in <(String, Widget)>[
    ('wordmark', AbBrandMark()),
    ('lockup', AbBrandMark.lockup()),
    ('mark-small', AbBrandMark.icon()),
    ('mark-transparent', AbBrandMark.icon(height: 48)),
  ]) {
    testWidgets('$name flips to its ink twin on the light preset', (
      tester,
    ) async {
      await tester.pumpWidget(underPreset(AbThemePreset.light, widget));
      expect(assetOf(tester), 'assets/logo/antgrid-$name-light.svg');

      await tester.pumpWidget(underPreset(AbThemePreset.zinc, widget));
      expect(assetOf(tester), 'assets/logo/antgrid-$name.svg');
    });
  }

  // Every asset the widget can name must actually ship, or the flip is a blank
  // slot in the field — flutter_svg fails at load, not at compile.
  test('every resolvable asset is declared in pubspec assets/logo/', () {
    final declared = Directory(
      'assets/logo',
    ).listSync().map((e) => 'assets/logo/${e.uri.pathSegments.last}');
    for (final preset in [AbThemePreset.light, AbThemePreset.zinc]) {
      final palette = kPresets[preset]!;
      for (final (cut, height) in const [
        ('wordmark', 20.0),
        ('mark+word', 44.0),
        ('mark', 18.0),
        ('mark', 48.0),
      ]) {
        expect(
          declared,
          contains(AbBrandMark.assetFor(cut, palette, height)),
          reason: '$cut @$height on $preset',
        );
      }
    }
  });
}
