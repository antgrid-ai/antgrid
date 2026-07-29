import 'package:antgrid/widgets/window_title_bar.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host([FakeWindowChrome? fake]) => ProviderScope(
  overrides: [
    windowChromeProvider.overrideWithValue(fake ?? FakeWindowChrome()),
  ],
  child: const MaterialApp(
    home: Scaffold(body: WindowTitleBar(child: Text('x'))),
  ),
);

void main() {
  testWidgets('Windows gets a top resize strip', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(_host());
      expect(find.byKey(WindowTitleBar.topResizeKey), findsOneWidget);
      expect(
        tester.getSize(find.byKey(WindowTitleBar.topResizeKey)).height,
        4.0,
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('dragging the strip resizes rather than moves the window', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final fake = FakeWindowChrome();
      await tester.pumpWidget(_host(fake));

      await tester.timedDrag(
        find.byKey(WindowTitleBar.topResizeKey),
        const Offset(0, -20),
        const Duration(milliseconds: 100),
      );
      await tester.pump();

      // The strip sits above the drag region in the same hit path, so a miss
      // here shows up as a window that moves when the user meant to resize.
      expect(fake.calls, ['startResizingTop']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('macOS gets none — the native frame owns resizing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_host());
      expect(find.byKey(WindowTitleBar.topResizeKey), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Linux gets none — the native bar is retained', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(_host());
      expect(find.byKey(WindowTitleBar.topResizeKey), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
