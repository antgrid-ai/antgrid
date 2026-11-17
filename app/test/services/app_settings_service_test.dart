import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppSettings.uiScale', () {
    test('defaults to 1.0 when no key is set', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.uiScale, 1.0);
    });

    test('round-trips through SharedPreferences', () async {
      useInMemoryPrefs({'antgrid.ui_scale.v1': 1.15});
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.uiScale, 1.15);
    });

    test('setUiScale persists the value', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();
      final container = ProviderContainer(
        overrides: [
          appSettingsServiceProvider.overrideWith(
            () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(appSettingsServiceProvider.notifier);

      await service.setUiScale(1.3);

      expect(prefs.getDouble('antgrid.ui_scale.v1'), 1.3);
      expect(service.state.uiScale, 1.3);
    });

    test('reset() clears uiScale back to 1.0', () async {
      useInMemoryPrefs({'antgrid.ui_scale.v1': 1.3});
      final prefs = await openAppSettingsPrefs();
      final container = ProviderContainer(
        overrides: [
          appSettingsServiceProvider.overrideWith(
            () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
          ),
        ],
      );
      addTearDown(container.dispose);
      final service = container.read(appSettingsServiceProvider.notifier);

      await service.reset();

      expect(service.state.uiScale, 1.0);
      expect(prefs.getDouble('antgrid.ui_scale.v1'), isNull);
    });
  });

  group('AppSettings.terminalZoom', () {
    Future<AppSettingsService> makeService({
      Map<String, Object> seed = const {},
    }) async {
      useInMemoryPrefs(seed);
      final prefs = await openAppSettingsPrefs();
      final container = ProviderContainer(
        overrides: [
          appSettingsServiceProvider.overrideWith(
            () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container.read(appSettingsServiceProvider.notifier);
    }

    test('defaults to 1.0 when no key is set', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.terminalZoom, 1.0);
    });

    test('round-trips through SharedPreferences', () async {
      useInMemoryPrefs({'antgrid.terminal_zoom.v1': 1.5});
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.terminalZoom, 1.5);
    });

    test('setTerminalZoom persists the value', () async {
      final service = await makeService();

      await service.setTerminalZoom(1.5);

      expect(service.state.terminalZoom, 1.5);
    });

    test('setTerminalZoom clamps below the 0.5 floor', () async {
      final service = await makeService();

      await service.setTerminalZoom(0.2);

      expect(service.state.terminalZoom, 0.5);
    });

    test('setTerminalZoom clamps above the 3.0 ceiling', () async {
      final service = await makeService();

      await service.setTerminalZoom(9.0);

      expect(service.state.terminalZoom, 3.0);
    });

    test('reset() clears terminalZoom back to 1.0', () async {
      final service = await makeService(
        seed: {'antgrid.terminal_zoom.v1': 2.0},
      );
      expect(service.state.terminalZoom, 2.0);

      await service.reset();

      expect(service.state.terminalZoom, 1.0);
    });
  });

  Future<AppSettingsService> makeService({
    Map<String, Object> seed = const {},
    Brightness Function()? platformBrightness,
  }) async {
    useInMemoryPrefs(seed);
    final prefs = await openAppSettingsPrefs();
    final container = ProviderContainer(
      overrides: [
        appSettingsServiceProvider.overrideWith(
          () => AppSettingsService(
            prefs,
            AppSettings.fromPrefs(prefs),
            platformBrightness: platformBrightness,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container.read(appSettingsServiceProvider.notifier);
  }

  group('AppSettings.reduceMotion', () {
    test('defaults to false when no key is set', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.reduceMotion, isFalse);
    });

    test('round-trips through SharedPreferences', () async {
      useInMemoryPrefs({'antgrid.reduce_motion.v1': true});
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.reduceMotion, isTrue);
    });

    test('setReduceMotion persists the value', () async {
      final service = await makeService();

      await service.setReduceMotion(true);

      expect(service.state.reduceMotion, isTrue);
    });

    test('reset() clears reduceMotion back to false', () async {
      final service = await makeService(
        seed: {'antgrid.reduce_motion.v1': true},
      );
      expect(service.state.reduceMotion, isTrue);

      await service.reset();

      expect(service.state.reduceMotion, isFalse);
    });
  });

  group('AppSettings.followSystemBrightness', () {
    test('defaults to true when no key is set', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.followSystemBrightness, isTrue);
    });

    test('round-trips an explicit opt-out through SharedPreferences', () async {
      useInMemoryPrefs({'antgrid.follow_system_brightness.v1': false});
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.followSystemBrightness, isFalse);
    });

    test('setFollowSystemBrightness persists the value', () async {
      final service = await makeService();

      await service.setFollowSystemBrightness(false);

      expect(service.state.followSystemBrightness, isFalse);
    });

    test('reset() restores and persists following on, even when used', () async {
      final service = await makeService(
        seed: {'antgrid.follow_system_brightness.v1': false},
      );
      expect(service.state.followSystemBrightness, isFalse);

      await service.reset();
      expect(service.state.followSystemBrightness, isTrue);

      // Written rather than removed, so the next launch's settle on an install
      // with prior use does not turn it back off.
      final prefs = await openAppSettingsPrefs();
      await settleFollowSystemDefault(prefs, hasPriorUse: () => true);
      expect(AppSettings.fromPrefs(prefs).followSystemBrightness, isTrue);
    });
  });

  group('settleFollowSystemDefault', () {
    Future<bool> settle({
      Map<String, Object> seed = const {},
      required bool hasPriorUse,
    }) async {
      useInMemoryPrefs(seed);
      final prefs = await openAppSettingsPrefs();
      await settleFollowSystemDefault(prefs, hasPriorUse: () => hasPriorUse);
      return AppSettings.fromPrefs(prefs).followSystemBrightness;
    }

    test('a fresh install follows the OS', () async {
      expect(await settle(hasPriorUse: false), isTrue);
    });

    test('an upgraded install that never chose keeps its preset', () async {
      expect(await settle(hasPriorUse: true), isFalse);
    });

    test('an explicit choice is never overwritten', () async {
      expect(
        await settle(
          seed: {'antgrid.follow_system_brightness.v1': true},
          hasPriorUse: true,
        ),
        isTrue,
      );
      expect(
        await settle(
          seed: {'antgrid.follow_system_brightness.v1': false},
          hasPriorUse: false,
        ),
        isFalse,
      );
    });

    test('the fresh-install answer latches once prior use appears', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();
      await settleFollowSystemDefault(prefs, hasPriorUse: () => false);
      await settleFollowSystemDefault(prefs, hasPriorUse: () => true);

      expect(AppSettings.fromPrefs(prefs).followSystemBrightness, isTrue);
    });
  });

  group('theme pick under follow-system', () {
    // (preset picked, OS brightness, following still on afterwards)
    for (final (preset, os, stillFollows) in [
      (AbThemePreset.slate, Brightness.light, false),
      (AbThemePreset.light, Brightness.dark, false),
      (AbThemePreset.slate, Brightness.dark, true),
      (AbThemePreset.light, Brightness.light, true),
    ]) {
      test('${preset.name} under OS ${os.name} -> following '
          '${stillFollows ? 'stays on' : 'switches off'}', () async {
        final service = await makeService(platformBrightness: () => os);

        await service.setPreset(preset);

        expect(service.state.preset, preset);
        expect(service.state.followSystemBrightness, stillFollows);
        final persisted = AppSettings.fromPrefs(await openAppSettingsPrefs());
        expect(persisted.followSystemBrightness, stillFollows);
      });
    }

    test('custom colours under OS light switch following off', () async {
      final service = await makeService(
        platformBrightness: () => Brightness.light,
      );

      await service.setCustomColors(bg: const Color(0xFF202020));

      expect(service.state.preset, AbThemePreset.custom);
      expect(service.state.followSystemBrightness, isFalse);
    });
  });

  group('AppSettings.hideGitIgnoredFiles', () {
    test('defaults to false when no key is set', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      // The tree shows everything out of the box — the decision most
      // likely to be "tidied" into the opposite by someone who finds a
      // show-everything tree surprising.
      expect(settings.hideGitIgnoredFiles, isFalse);
    });

    test('round-trips through SharedPreferences', () async {
      useInMemoryPrefs({'antgrid.hide_git_ignored_files.v1': true});
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.hideGitIgnoredFiles, isTrue);
    });

    test('setHideGitIgnoredFiles persists the value', () async {
      final service = await makeService();

      await service.setHideGitIgnoredFiles(true);

      expect(service.state.hideGitIgnoredFiles, isTrue);
    });

    test('reset() clears hideGitIgnoredFiles back to false', () async {
      final service = await makeService(
        seed: {'antgrid.hide_git_ignored_files.v1': true},
      );
      expect(service.state.hideGitIgnoredFiles, isTrue);

      await service.reset();

      expect(service.state.hideGitIgnoredFiles, isFalse);
    });
  });
}
