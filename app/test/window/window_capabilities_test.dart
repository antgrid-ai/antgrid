import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/window/window_capabilities.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('appOwnsWindowChrome', () {
    test('is true on Windows and macOS', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(appOwnsWindowChrome, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(appOwnsWindowChrome, isTrue);
    });

    test('is false on Linux — ships TitleBarStyle.normal until verified', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(appOwnsWindowChrome, isFalse);
    });

    test('is false on mobile', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(appOwnsWindowChrome, isFalse);
    });
  });

  group('paintsWindowControls', () {
    test('is true only on Windows', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(paintsWindowControls, isTrue);
    });

    test('is false on macOS — native traffic lights are kept', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(paintsWindowControls, isFalse);
    });

    test('is false on Linux — the native bar draws them', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(paintsWindowControls, isFalse);
    });
  });

  group('titleBarLeftInset', () {
    test('reserves 78px for macOS traffic lights', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(titleBarLeftInset, 78.0);
    });

    test('is zero elsewhere', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(titleBarLeftInset, 0.0);
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(titleBarLeftInset, 0.0);
    });
  });

  test(
    'titleBarHeight margins the search field by space6 on top and bottom',
    () {
      expect(titleBarHeight, AbTokens.rowHeightXs + AbTokens.space6 * 2);
    },
  );
}
