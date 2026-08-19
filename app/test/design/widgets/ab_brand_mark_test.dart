import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_brand_mark.dart';
import '../test_harness.dart';

void main() {
  testWidgets('AbBrandMark renders the wordmark asset', (
    tester,
  ) async {
    await pumpAntgrid(tester, const AbBrandMark());
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    final loader = svg.bytesLoader as SvgAssetLoader;
    expect(loader.assetName, 'assets/logo/antgrid-wordmark.svg');
  });

  testWidgets('AbBrandMark honours the height parameter', (tester) async {
    await pumpAntgrid(tester, const AbBrandMark(height: 32));
    final svg = tester.widget<SvgPicture>(find.byType(SvgPicture));
    expect(svg.height, 32);
  });
}
