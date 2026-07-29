import 'package:antgrid/design/widgets/ab_window_controls.dart';
import 'package:antgrid/window/window_chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(FakeWindowChrome fake, {bool maximized = false}) {
  return ProviderScope(
    overrides: [
      windowChromeProvider.overrideWithValue(fake),
      windowMaximizedProvider.overrideWith(
        () => FixedWindowMaximized(maximized),
      ),
    ],
    child: const MaterialApp(home: Scaffold(body: AbWindowControls())),
  );
}

void main() {
  testWidgets('renders nothing on macOS — traffic lights are native', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      // Tooltip finder, not byType(IconButton): AbIconButton is not a Material
      // IconButton, so a byType check would pass vacuously on every platform.
      expect(find.byTooltip('Close'), findsNothing);
      expect(tester.getSize(find.byType(AbWindowControls)), Size.zero);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('renders nothing on Linux — the native bar draws them', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      expect(tester.getSize(find.byType(AbWindowControls)), Size.zero);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('renders three controls on Windows', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome()));
      expect(find.byTooltip('Minimize'), findsOneWidget);
      expect(find.byTooltip('Maximize'), findsOneWidget);
      expect(find.byTooltip('Close'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('shows Restore instead of Maximize when maximized', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(_host(FakeWindowChrome(), maximized: true));
      expect(find.byTooltip('Restore'), findsOneWidget);
      expect(find.byTooltip('Maximize'), findsNothing);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('each control invokes its window action', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final fake = FakeWindowChrome();
      await tester.pumpWidget(_host(fake));

      await tester.tap(find.byTooltip('Minimize'));
      await tester.tap(find.byTooltip('Maximize'));
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();

      expect(fake.calls, ['minimize', 'toggleMaximize', 'close']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
