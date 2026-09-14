// A location that names a settings block reaches the settings screen as pending
// state, not as a call: the nav layer writes the surface but cannot reach the
// screen that surface mounts, and a link can land before that screen exists.
// The screen drains the provider on mount and on change, and scrolling the list
// is all it does — a section is a destination, not a mode.
import 'package:antgrid/models/pending_nav.dart';
import 'package:antgrid/models/settings_section.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/screens/app_settings_screen.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// No project is focused in this suite, so a section the screen should honour
/// carries that same stamp.
PendingNav<SettingsSection> _pending(SettingsSection section) =>
    (target: null, value: section);

Future<AppSettingsService> _buildService() async {
  useInMemoryPrefs();
  final prefs = await openAppSettingsPrefs();
  return AppSettingsService(prefs, AppSettings.fromPrefs(prefs));
}

/// Runs [body] against the settings screen on a desktop-sized viewport.
///
/// The platform override is cleared inside the test body, not in a tearDown:
/// the binding asserts every foundation debug variable is unset before tearDown
/// runs. It has to stay set for the whole body, since the screen reads the
/// platform while it lays out.
Future<void> _withSettings(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body, {
  List<Override> extraOverrides = const [],
}) async {
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = await _buildService();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsServiceProvider.overrideWith(() => service),
          ...extraOverrides,
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
    await body(container);
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

/// True while the section's frame is inside the scroll viewport.
bool _onScreen(WidgetTester tester, SettingsSection section) {
  final finder = find.byKey(settingsSectionKey(section));
  if (finder.evaluate().isEmpty) return false;
  final rect = tester.getRect(finder);
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  return rect.top < screen.height && rect.bottom > 0;
}

void main() {
  testWidgets('every section is addressable by its key', (tester) async {
    await _withSettings(tester, (_) async {
      for (final section in SettingsSection.values) {
        // BILLING is native-platform only and this suite runs on desktop; the
        // rest are on screen or below the fold, but always built.
        if (section == SettingsSection.billing) continue;
        expect(
          find.byKey(settingsSectionKey(section)),
          findsOneWidget,
          reason: section.name,
        );
      }
    });
  });

  // The half a lazy list would have broken: ACCOUNT is the last block, far
  // below the fold, so it is exactly the section whose element would not exist
  // to be scrolled to.
  testWidgets('a section pending before mount is scrolled to on mount', (
    tester,
  ) async {
    await _withSettings(
      tester,
      extraOverrides: [
        pendingSettingsSectionProvider.overrideWith(
          () => ValueController(_pending(SettingsSection.account)),
        ),
      ],
      (container) async {
        expect(_onScreen(tester, SettingsSection.account), isTrue);
        // Spent on consumption, so a later mount can't replay the link.
        expect(container.read(pendingSettingsSectionProvider), isNull);
      },
    );
  });

  testWidgets('a section pending while mounted is scrolled to on change', (
    tester,
  ) async {
    await _withSettings(tester, (container) async {
      expect(_onScreen(tester, SettingsSection.account), isFalse);

      container
          .read(pendingSettingsSectionProvider.notifier)
          .set(_pending(SettingsSection.account));
      await tester.pumpAndSettle();

      expect(_onScreen(tester, SettingsSection.account), isTrue);
      expect(container.read(pendingSettingsSectionProvider), isNull);
    });
  });

  // Null is what a location naming no section writes; it must leave the list
  // exactly where it found it.
  testWidgets('a null pending section scrolls nowhere', (tester) async {
    await _withSettings(tester, (container) async {
      final before = tester.getRect(
        find.byKey(settingsSectionKey(SettingsSection.appearance)),
      );

      container.read(pendingSettingsSectionProvider.notifier).set(null);
      await tester.pumpAndSettle();

      expect(
        tester.getRect(
          find.byKey(settingsSectionKey(SettingsSection.appearance)),
        ),
        before,
      );
    });
  });

  // The codec degrades rather than rejects an unknown value; the destination
  // has to be just as forgiving about a section this build does not render.
  testWidgets('a section this build omits is dropped, not thrown', (
    tester,
  ) async {
    await _withSettings(
      tester,
      extraOverrides: [
        pendingSettingsSectionProvider.overrideWith(
          () => ValueController(_pending(SettingsSection.billing)),
        ),
      ],
      (container) async {
        expect(
          find.byKey(settingsSectionKey(SettingsSection.billing)),
          findsNothing,
        );
        expect(container.read(pendingSettingsSectionProvider), isNull);
      },
    );
  });
}
