import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/screens/app_settings_screen.dart';
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

Future<({AppSettingsService service, SharedPreferencesWithCache prefs})>
_buildService() async {
  useInMemoryPrefs();
  final prefs = await openAppSettingsPrefs();
  final seed = AppSettings.fromPrefs(prefs);
  return (service: AppSettingsService(prefs, seed), prefs: prefs);
}

/// Drags the ListView until 'Anonymous usage analytics' is fully on-screen.
/// The PRIVACY section is placed near the bottom of the settings screen, so a
/// fresh pump may leave it off-screen — and the ListView's cache extent can
/// build the row while it is still below the fold, so existence in the tree
/// is not enough for a hittable tap; ensureVisible does the final alignment.
Future<void> _scrollToPrivacy(WidgetTester tester) async {
  final label = find.text('Anonymous usage analytics');
  while (label.evaluate().isEmpty) {
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(label);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('telemetry toggle row is visible with correct label', (
    tester,
  ) async {
    // flutter_test defaults to Android; stay on desktop to avoid mobile-only
    // layout branches that change which sections are shown.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final (:service, :prefs) = await _buildService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsServiceProvider.overrideWith(() => service),
        ],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const AppSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToPrivacy(tester);

    expect(find.text('Anonymous usage analytics'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('tapping telemetry toggle flips telemetryEnabled to false', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final (:service, :prefs) = await _buildService();

    // Seed: telemetryEnabled = true (the default).
    expect(AppSettings.fromPrefs(prefs).telemetryEnabled, isTrue);

    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsServiceProvider.overrideWith(() => service),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: buildAbTheme(),
              home: const AppSettingsScreen(),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToPrivacy(tester);

    // Tap the toggle row label — the parent GestureDetector covers the full
    // row with HitTestBehavior.opaque so the text is the tap target.
    await tester.tap(find.text('Anonymous usage analytics'));
    await tester.pumpAndSettle();

    // Provider state must have flipped.
    expect(container.read(appSettingsServiceProvider).telemetryEnabled, isFalse);

    // Persisted prefs must also reflect the change.
    expect(AppSettings.fromPrefs(prefs).telemetryEnabled, isFalse);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'tapping telemetry toggle twice restores telemetryEnabled to true',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final (:service, :prefs) = await _buildService();

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsServiceProvider.overrideWith(() => service),
          ],
          child: Consumer(
            builder: (context, ref, _) {
              container = ProviderScope.containerOf(context);
              return MaterialApp(
                theme: buildAbTheme(),
                home: const AppSettingsScreen(),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _scrollToPrivacy(tester);

      await tester.tap(find.text('Anonymous usage analytics'));
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsServiceProvider).telemetryEnabled,
        isFalse,
      );

      await tester.tap(find.text('Anonymous usage analytics'));
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsServiceProvider).telemetryEnabled,
        isTrue,
      );

      debugDefaultTargetPlatformOverride = null;
    },
  );
}
