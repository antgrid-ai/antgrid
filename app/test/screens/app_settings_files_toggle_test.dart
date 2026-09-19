import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
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

/// Brings 'Hide git-ignored files' fully on-screen — the FILES section sits
/// below the fold on a fresh pump, same as PRIVACY in the telemetry toggle
/// test this one is modeled on.
Future<void> _scrollToFiles(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Hide git-ignored files'));
  await tester.pumpAndSettle();
}

/// The RENDERED state of the FILES row's switch: the track paints the accent
/// when on and the elevated background when off.
bool _toggleIsOn(WidgetTester tester) {
  final row = find.ancestor(
    of: find.text('Hide git-ignored files'),
    matching: find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_ToggleRow',
    ),
  );
  final track = tester.widget<AnimatedContainer>(
    find.descendant(of: row, matching: find.byType(AnimatedContainer)),
  );
  final color = (track.decoration! as BoxDecoration).color;
  return color == kDefaultPalette.accent;
}

void main() {
  testWidgets('hide-ignored-files toggle row is visible with correct label', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;

    final (:service, :prefs) = await _buildService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsServiceProvider.overrideWith(() => service)],
        child: MaterialApp(
          theme: buildAbTheme(),
          home: const AppSettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _scrollToFiles(tester);

    expect(find.text('Hide git-ignored files'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'the tree shows everything by default — the switch RENDERS off, then on',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final (:service, prefs: _) = await _buildService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsServiceProvider.overrideWith(() => service)],
          child: MaterialApp(
            theme: buildAbTheme(),
            home: const AppSettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _scrollToFiles(tester);

      // The pixels, not the notifier: `onTap` computes its new value from the
      // settings independently of what `enabled:` is wired to, so a tap test
      // passes just as happily with the switch painted backwards.
      expect(_toggleIsOn(tester), isFalse);

      await tester.tap(find.text('Hide git-ignored files'));
      await tester.pumpAndSettle();

      expect(_toggleIsOn(tester), isTrue);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'tapping the toggle flips hideGitIgnoredFiles to true',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final (:service, :prefs) = await _buildService();

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsServiceProvider.overrideWith(() => service)],
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

      await _scrollToFiles(tester);

      await tester.tap(find.text('Hide git-ignored files'));
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsServiceProvider).hideGitIgnoredFiles,
        isTrue,
      );
      expect(AppSettings.fromPrefs(prefs).hideGitIgnoredFiles, isTrue);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'tapping the toggle twice restores hideGitIgnoredFiles to false',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final (:service, :prefs) = await _buildService();

      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appSettingsServiceProvider.overrideWith(() => service)],
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

      await _scrollToFiles(tester);

      await tester.tap(find.text('Hide git-ignored files'));
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsServiceProvider).hideGitIgnoredFiles,
        isTrue,
      );

      await tester.tap(find.text('Hide git-ignored files'));
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsServiceProvider).hideGitIgnoredFiles,
        isFalse,
      );

      debugDefaultTargetPlatformOverride = null;
    },
  );
}
