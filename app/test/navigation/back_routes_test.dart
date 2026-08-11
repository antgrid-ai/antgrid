// app/test/navigation/back_routes_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/navigation/back_intent.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';

NavLocation _loc(String projectId) => NavLocation(
  target: LocalProject(projectId),
  surface: WorkbenchSurface.workspace,
);

void main() {
  late ProviderContainer c;

  setUp(() {
    c = ProviderContainer();
    addTearDown(c.dispose);
  });

  tearDown(() {
    backIntentClock = DateTime.now;
    backIntentExit = () => Future<void>.value();
  });

  /// The platform override must be cleared inside the test body — the binding
  /// asserts every foundation debug variable is unset before tearDown runs.
  Future<void> onPlatform(
    TargetPlatform platform,
    Future<void> Function() body,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  Future<void> pumpScope(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: AppBackScope(child: Scaffold(body: SizedBox.shrink())),
        ),
      ),
    );
  }

  /// The system back gesture/button, as the framework delivers it.
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pump();
  }

  testWidgets('system back runs a registered handler instead of popping', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.android, () async {
      await pumpScope(tester);

      var consumed = 0;
      c.read(backHandlerRegistryProvider).register(
        priority: BackPriority.fileViewer,
        onBack: () {
          consumed++;
          return true;
        },
      );

      await systemBack(tester);
      expect(consumed, 1);
      // Still mounted: the route was not popped.
      expect(find.byType(AppBackScope), findsOneWidget);
    });
  });

  testWidgets('system back falls through to history', (tester) async {
    await onPlatform(TargetPlatform.android, () async {
      await pumpScope(tester);

      final nav = c.read(navControllerProvider.notifier);
      nav.commit(_loc('a'));
      nav.commit(_loc('b'));

      await systemBack(tester);
      expect(c.read(navControllerProvider).current, _loc('a'));
    });
  });

  testWidgets('an exhausted system back arms, then exits on the second press', (
    tester,
  ) async {
    await onPlatform(TargetPlatform.android, () async {
      var now = DateTime(2026, 1, 1, 12);
      backIntentClock = () => now;
      var exits = 0;
      backIntentExit = () async => exits++;

      await pumpScope(tester);

      await systemBack(tester);
      expect(exits, 0);
      expect(c.read(backExitGateProvider), isNotNull);

      now = now.add(const Duration(milliseconds: 400));
      await systemBack(tester);
      await tester.pumpAndSettle();
      expect(exits, 1);

      // Drain the arm toast's auto-dismiss timer.
      await tester.pump(kBackExitWindow);
    });
  });

  testWidgets('desktop never exits, however exhausted', (tester) async {
    await onPlatform(TargetPlatform.windows, () async {
      backIntentExit = () async => fail('desktop must not exit');

      await pumpScope(tester);

      await systemBack(tester);
      await systemBack(tester);
      expect(c.read(backExitGateProvider), isNull);
    });
  });
}
