import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/main.dart' show systemBarStyleFor;
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

/// Minimal stand-in for AbApp's MaterialApp builder wiring: same settings →
/// palette → [systemBarStyleFor] → AnnotatedRegion chain, without dragging in
/// the auth/update home subtree.
class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(appSettingsServiceProvider);
    final palette = paletteFor(
      preset: settings.preset,
      customBg: settings.customBg,
      customPrimary: settings.customPrimary,
      customAccent: settings.customAccent,
    );
    return MaterialApp(
      theme: buildAbTheme(palette),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBarStyleFor(palette),
        child: child!,
      ),
      home: const SizedBox.shrink(),
    );
  }
}

void main() {
  group('systemBarStyleFor', () {
    test('dark palette -> light bar icons over transparent bars', () {
      final style = systemBarStyleFor(kPresets[AbThemePreset.zinc]!);
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Colors.transparent);
      expect(style.statusBarIconBrightness, Brightness.light);
      expect(style.systemNavigationBarIconBrightness, Brightness.light);
      // iOS semantics: brightness of the bar BACKGROUND, inverse of icons.
      expect(style.statusBarBrightness, Brightness.dark);
    });

    test('light palette -> dark bar icons over transparent bars', () {
      final style = systemBarStyleFor(kPresets[AbThemePreset.light]!);
      expect(style.statusBarColor, Colors.transparent);
      expect(style.systemNavigationBarColor, Colors.transparent);
      expect(style.statusBarIconBrightness, Brightness.dark);
      expect(style.systemNavigationBarIconBrightness, Brightness.dark);
      expect(style.statusBarBrightness, Brightness.light);
    });
  });

  testWidgets('bar icon brightness flips on a live preset change', (
    tester,
  ) async {
    useInMemoryPrefs();
    final prefs = await openAppSettingsPrefs();
    final service = AppSettingsService(prefs, AppSettings.fromPrefs(prefs));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsServiceProvider.overrideWith(() => service)],
        child: const _Harness(),
      ),
    );

    SystemUiOverlayStyle regionStyle() => tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .value;

    // Default preset (zinc) is dark -> light icons.
    expect(regionStyle().statusBarIconBrightness, Brightness.light);

    await service.setPreset(AbThemePreset.light);
    await tester.pump();

    expect(regionStyle().statusBarIconBrightness, Brightness.dark);
    expect(regionStyle().systemNavigationBarIconBrightness, Brightness.dark);
  });
}
