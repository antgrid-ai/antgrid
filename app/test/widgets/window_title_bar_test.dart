import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(FakeWindowChrome fake) {
  return ProviderScope(
    overrides: [windowChromeProvider.overrideWithValue(fake)],
    child: const MaterialApp(
      home: Scaffold(
        body: WindowTitleBar(child: Row(children: [Text('content'), Spacer()])),
      ),
    ),
  );
}

void main() {
  testWidgets('is 32px tall', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      expect(
        tester.getSize(find.byType(WindowTitleBar)).height,
        AbTokens.rowHeightSm,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('dragging the empty centre moves the window', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final fake = FakeWindowChrome();
      await tester.pumpWidget(_host(fake));

      await tester.timedDrag(
        find.byKey(WindowTitleBar.dragRegionKey),
        const Offset(40, 0),
        const Duration(milliseconds: 100),
      );
      await tester.pump();

      expect(fake.calls, contains('startDragging'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('double-clicking the drag region toggles maximize', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final fake = FakeWindowChrome();
      await tester.pumpWidget(_host(fake));

      final region = find.byKey(WindowTitleBar.dragRegionKey);
      await tester.tap(region);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(region);
      await tester.pump(const Duration(milliseconds: 400));

      expect(fake.calls, contains('toggleMaximize'));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a mouse press-hold-then-drag still moves the window', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final fake = FakeWindowChrome();
      await tester.pumpWidget(_host(fake));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(WindowTitleBar.dragRegionKey)),
        kind: PointerDeviceKind.mouse,
      );
      // Past kLongPressTimeout (500ms) before moving: a long-press recognizer
      // that accepted mouse pointers would have claimed the arena by now and
      // popped the system menu instead.
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(40, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(fake.calls, contains('startDragging'));
      expect(fake.calls, isNot(contains('popUpWindowMenu')));
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS reserves 78px for the traffic lights', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      final padding = tester.widget<Padding>(
        find.byKey(WindowTitleBar.insetKey),
      );
      expect((padding.padding as EdgeInsets).left, 78.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Windows reserves no left inset', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      final padding = tester.widget<Padding>(
        find.byKey(WindowTitleBar.insetKey),
      );
      expect((padding.padding as EdgeInsets).left, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Linux renders no drag region — the native bar owns it', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      expect(find.byKey(WindowTitleBar.dragRegionKey), findsNothing);
      expect(find.text('content'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
