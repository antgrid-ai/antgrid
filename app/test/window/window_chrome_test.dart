import 'package:antgrid/window/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Windows and macOS hide the OS title bar', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(desktopTitleBarStyle(), TitleBarStyle.hidden);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(desktopTitleBarStyle(), TitleBarStyle.hidden);
  });

  test('Linux keeps the OS title bar until the custom path is verified', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(desktopTitleBarStyle(), TitleBarStyle.normal);
  });

  test('FakeWindowChrome records calls for widget tests', () async {
    final fake = FakeWindowChrome();
    await fake.startDragging();
    await fake.toggleMaximize();
    await fake.minimize();
    await fake.close();
    await fake.popUpWindowMenu();
    expect(fake.calls, [
      'startDragging',
      'toggleMaximize',
      'minimize',
      'close',
      'popUpWindowMenu',
    ]);
  });
}
