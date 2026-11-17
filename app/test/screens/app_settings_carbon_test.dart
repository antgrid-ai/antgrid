import 'dart:ui' show Tristate;

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/settings_section.dart';
import 'package:antgrid/screens/app_settings_screen.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/widgets/carbon_choice_tile.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';

/// Pumps the screen on a desktop-density viewport and hands [body] the
/// container. The platform override is cleared inside the body: the binding
/// asserts every foundation debug variable is unset before tearDown.
Future<void> _withSettings(
  WidgetTester tester,
  Future<void> Function(ProviderContainer container) body, {
  Size size = const Size(1000, 800),
  VoidCallback? onClose,
}) async {
  try {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    useInMemoryPrefs();
    final prefs = await openAppSettingsPrefs();
    final service = AppSettingsService(prefs, AppSettings.fromPrefs(prefs));
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsServiceProvider.overrideWith(() => service)],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              theme: buildAbTheme(),
              home: AppSettingsScreen(onClose: onClose),
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

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

/// Whether the UI size tile named [label] announces itself selected. Scoped
/// to its section: the theme presets also have a 'Default' tile.
Tristate _selected(WidgetTester tester, String label) => tester
    .getSemantics(
      find.descendant(
        of: find.byKey(settingsSectionKey(SettingsSection.uiSize)),
        matching: find.bySemanticsLabel(label),
      ),
    )
    .getSemanticsData()
    .flagsCollection
    .isSelected;

void main() {
  testWidgets('the screen draws no Ab widget inside its Carbon scope', (
    tester,
  ) async {
    await _withSettings(tester, (_) async {
      expect(abWidgetsInScope(tester), isEmpty);
    });
  });

  testWidgets('the header names the surface and closes it', (tester) async {
    var closed = 0;
    await _withSettings(tester, onClose: () => closed++, (_) async {
      expect(find.text('App settings'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is CarbonButton && w.semanticLabel == 'Close settings',
        ),
      );
      await tester.pumpAndSettle();
      expect(closed, 1);
    });
  });

  testWidgets('the body is one eager scroller with sentence-case titles', (
    tester,
  ) async {
    await _withSettings(tester, (_) async {
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      for (final title in [
        'Appearance',
        'UI size',
        'Accessibility',
        'Files',
        'Privacy',
        'Account',
      ]) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.text('APPEARANCE'), findsNothing);
    });
  });

  testWidgets('the column is start-aligned and no wider than 672', (
    tester,
  ) async {
    await _withSettings(tester, (_) async {
      final rect = tester.getRect(find.byType(CarbonFormSection).first);
      expect(rect.width, lessThanOrEqualTo(672));
      expect(rect.left, lessThan(40));
    });
  });

  testWidgets('a UI size tile applies its scale and announces selection', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _withSettings(tester, (container) async {
      expect(_selected(tester, 'Default'), Tristate.isTrue);
      expect(_selected(tester, 'Large'), Tristate.isFalse);

      await _tap(tester, find.text('Large'));

      expect(container.read(appSettingsServiceProvider).uiScale, 1.30);
      expect(_selected(tester, 'Large'), Tristate.isTrue);
      expect(_selected(tester, 'Default'), Tristate.isFalse);
    });
    semantics.dispose();
  });

  testWidgets('a preset tile applies its preset', (tester) async {
    await _withSettings(tester, (container) async {
      await _tap(tester, find.text('Slate'));
      expect(
        container.read(appSettingsServiceProvider).preset,
        AbThemePreset.slate,
      );
    });
  });

  testWidgets('every tile owns a focusable interaction of its own', (
    tester,
  ) async {
    await _withSettings(tester, (_) async {
      final tiles = find.byType(CarbonChoiceTile);
      // Seven presets plus four sizes.
      expect(tiles, findsNWidgets(11));
      expect(
        find.descendant(of: tiles, matching: find.byType(CarbonInteraction)),
        findsNWidgets(11),
      );
    });
  });

  testWidgets('the Custom tile reveals swatches that open a Carbon picker', (
    tester,
  ) async {
    await _withSettings(tester, (container) async {
      expect(find.text('Custom colors'), findsNothing);
      await _tap(tester, find.text('Custom'));
      expect(
        container.read(appSettingsServiceProvider).preset,
        AbThemePreset.custom,
      );
      expect(find.text('Custom colors'), findsOneWidget);

      final before = container.read(appSettingsServiceProvider).customBg;
      await _tap(tester, find.text('Background'));
      expect(find.byType(CarbonModal), findsOneWidget);
      expect(find.text('Pick background'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(CarbonModal), findsNothing);
      expect(container.read(appSettingsServiceProvider).customBg, before);
    });
  });

  testWidgets('Reset to defaults restores the settings', (tester) async {
    await _withSettings(tester, (container) async {
      await _tap(tester, find.text('Reduce motion'));
      expect(container.read(appSettingsServiceProvider).reduceMotion, isTrue);

      await _tap(tester, find.text('Reset to defaults'));
      expect(container.read(appSettingsServiceProvider).reduceMotion, isFalse);
    });
  });

  testWidgets('Delete account opens a modal that asks for DELETE', (
    tester,
  ) async {
    await _withSettings(tester, (_) async {
      await _tap(tester, find.text('Delete account'));
      expect(find.byType(CarbonModal), findsOneWidget);
      expect(find.text('Delete account?'), findsOneWidget);
      expect(find.text('Type DELETE to confirm'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(CarbonModal), findsNothing);
    });
  });

  testWidgets('a phone lays the tiles out without overflow', (tester) async {
    await _withSettings(tester, size: const Size(390, 844), (_) async {
      await tester.ensureVisible(find.text('Large'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.text('Large')).right, lessThanOrEqualTo(390));
    });
  });
}
