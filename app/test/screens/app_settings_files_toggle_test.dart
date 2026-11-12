import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
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

/// Brings 'Hide git-ignored files' fully on-screen — the Files section sits
/// below the fold on a fresh pump, same as PRIVACY in the telemetry toggle
/// test this one is modeled on.
Future<void> _scrollToFiles(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Hide git-ignored files'));
  await tester.pumpAndSettle();
}

/// The state the Files row's switch ANNOUNCES. Read from the toggle's own
/// semantics node, so it is the same answer a screen reader gets and no colour
/// or private widget type is involved.
bool _toggleIsOn(WidgetTester tester) {
  final node = tester.getSemantics(
    find.bySemanticsLabel('Hide git-ignored files'),
  );
  return node.getSemanticsData().flagsCollection.isToggled == Tristate.isTrue;
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

      final semantics = tester.ensureSemantics();
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

      // What the switch shows, not the notifier: the tap handler computes its
      // new value from the settings independently of what `value:` is wired
      // to, so a tap test passes just as happily with the switch backwards.
      expect(_toggleIsOn(tester), isFalse);

      // The label is part of the toggle's tap target.
      await tester.tap(find.text('Hide git-ignored files'));
      await tester.pumpAndSettle();

      expect(_toggleIsOn(tester), isTrue);

      semantics.dispose();
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
