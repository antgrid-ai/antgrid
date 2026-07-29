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
    // The transparent variant specifically: the plated antgrid-mark.svg paints
    // a #18181B tile on the #09090B bar, which reads as elevation.
    expect(assetOf(tester), 'assets/logo/antgrid-mark-transparent.svg');
  });

  testWidgets('.icon() applies no colorFilter — the asset is two-tone', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AbBrandMark.icon()));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.colorFilter, isNull);
  });
}
