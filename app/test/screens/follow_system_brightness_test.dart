import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/main.dart' show effectivePaletteFor, systemBarStyleFor;
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

const _probeKey = Key('probe');

/// Minimal stand-in for AbApp's MaterialApp builder wiring: same settings →
/// chosen palette → [effectivePaletteFor] (via platformBrightnessOf) →
/// Theme swap + [systemBarStyleFor] chain, without the auth/update subtree.
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
    final theme = buildAbTheme(palette);
    return MaterialApp(
      theme: theme,
      darkTheme: theme,
      builder: (context, child) {
        final effectivePalette = effectivePaletteFor(
          settings: settings,
          chosen: palette,
          platformBrightness: MediaQuery.platformBrightnessOf(context),
        );
        final effectiveTheme = identical(effectivePalette, palette)
            ? theme
            : buildAbTheme(effectivePalette);
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemBarStyleFor(effectivePalette),
          child: Theme(data: effectiveTheme, child: child!),
        );
      },
      home: const SizedBox.shrink(key: _probeKey),
    );
  }
}

void main() {
  group('effectivePaletteFor', () {
    const zinc = AppSettings(preset: AbThemePreset.zinc);
    const light = AppSettings(preset: AbThemePreset.light);
    final zincPalette = kPresets[AbThemePreset.zinc]!;
    final lightPalette = kPresets[AbThemePreset.light]!;

    test('off -> chosen palette regardless of OS brightness', () {
      for (final brightness in Brightness.values) {
        expect(
          effectivePaletteFor(
            settings: zinc,
            chosen: zincPalette,
            platformBrightness: brightness,
          ),
          same(zincPalette),
        );
      }
    });

    test('on + OS light -> the light preset palette', () {
      expect(
        effectivePaletteFor(
          settings: zinc.copyWith(followSystemBrightness: true),
          chosen: zincPalette,
          platformBrightness: Brightness.light,
        ),
        same(lightPalette),
      );
    });

    test('on + OS dark -> the chosen preset palette', () {
      expect(
        effectivePaletteFor(
          settings: zinc.copyWith(followSystemBrightness: true),
          chosen: zincPalette,
          platformBrightness: Brightness.dark,
        ),
        same(zincPalette),
      );
    });

    test('on + OS dark with light chosen -> default dark palette', () {
      expect(
        effectivePaletteFor(
          settings: light.copyWith(followSystemBrightness: true),
          chosen: lightPalette,
          platformBrightness: Brightness.dark,
        ),
        same(kDefaultPalette),
      );
    });
  });

  testWidgets('effective theme tracks live OS brightness flips', (
    tester,
  ) async {
    useInMemoryPrefs();
    final prefs = await openAppSettingsPrefs();
    final service = AppSettingsService(prefs, AppSettings.fromPrefs(prefs));

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [appSettingsServiceProvider.overrideWith(() => service)],
        child: const _Harness(),
      ),
    );

    AbColors effective() =>
        Theme.of(tester.element(find.byKey(_probeKey))).extension<AbColors>()!;

    final zinc = kPresets[AbThemePreset.zinc]!;
    final light = kPresets[AbThemePreset.light]!;

    // Follow off (default): chosen preset (zinc) under either OS brightness.
    expect(effective().bgDeepest, zinc.bgDeepest);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    expect(effective().bgDeepest, zinc.bgDeepest);

    // Follow on + OS light: the light preset takes over.
    await service.setFollowSystemBrightness(true);
    await tester.pump();
    expect(effective().bgDeepest, light.bgDeepest);

    // OS flips dark: back to the chosen (zinc) preset.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(effective().bgDeepest, zinc.bgDeepest);
  });
}
