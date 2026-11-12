import 'package:antgrid/design/ab_tokens.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Future<Size> _renderedSize(WidgetTester tester) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Text('W', key: const Key('w'), style: AbTokens.sansStyle()),
      ),
    ),
  );
  return tester.getSize(find.byKey(const Key('w')));
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  const mobile = {
    'fontXxs': 11.0,
    'fontXs': 12.0,
    'fontSm': 13.0,
    'fontMd': 15.0,
    'fontBody': 17.0,
    'fontLg': 20.0,
    'fontXl': 22.0,
    'fontDisplaySm': 28.0,
    'fontDisplayMd': 34.0,
    'fontDisplayLg': 40.0,
  };
  const desktop = {
    'fontXxs': 10.0,
    'fontXs': 11.0,
    'fontSm': 12.0,
    'fontMd': 13.0,
    'fontBody': 14.0,
    'fontLg': 16.0,
    'fontXl': 18.0,
    'fontDisplaySm': 24.0,
    'fontDisplayMd': 32.0,
    'fontDisplayLg': 40.0,
  };

  Map<String, double> read() => {
    'fontXxs': AbTokens.fontXxs,
    'fontXs': AbTokens.fontXs,
    'fontSm': AbTokens.fontSm,
    'fontMd': AbTokens.fontMd,
    'fontBody': AbTokens.fontBody,
    'fontLg': AbTokens.fontLg,
    'fontXl': AbTokens.fontXl,
    'fontDisplaySm': AbTokens.fontDisplaySm,
    'fontDisplayMd': AbTokens.fontDisplayMd,
    'fontDisplayLg': AbTokens.fontDisplayLg,
  };

  for (final p in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('scale follows Apple text styles on $p', () {
      debugDefaultTargetPlatformOverride = p;
      expect(read(), mobile);
    });
  }

  for (final p in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  ]) {
    test('scale is unchanged on $p', () {
      debugDefaultTargetPlatformOverride = p;
      expect(read(), desktop);
    });
  }

  testWidgets('body text lays out taller on mobile than on desktop', (
    tester,
  ) async {
    // Reset inside the body: the binding checks for a leaked override before
    // any tearDown runs.
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(AbTokens.sansStyle().fontSize, 17);
      final mobileSize = await _renderedSize(tester);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(AbTokens.sansStyle().fontSize, 14);
      expect(AbTokens.monoStyle().fontSize, 14);
      final desktopSize = await _renderedSize(tester);

      expect(mobileSize.height, greaterThan(desktopSize.height));
      expect(mobileSize.width / desktopSize.width, closeTo(17 / 14, 0.02));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('terminal base size ignores the platform', () {
    for (final p in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = p;
      expect(AbTokens.terminalBaseFont, 14);
    }
  });

  test('touch control height equals the tap target', () {
    expect(AbTokens.touchControlMin, 44);
    expect(AbTokens.touchControlMin, AbTokens.tapTargetMin);
  });
}
