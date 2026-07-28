import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    test('defaults to false when no key is set', () async {
      useInMemoryPrefs();
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.followSystemBrightness, isFalse);
    });

    test('round-trips through SharedPreferences', () async {
      useInMemoryPrefs({'antgrid.follow_system_brightness.v1': true});
      final prefs = await openAppSettingsPrefs();

      final settings = AppSettings.fromPrefs(prefs);

      expect(settings.followSystemBrightness, isTrue);
    });

    test('setFollowSystemBrightness persists the value', () async {
      final service = await makeService();

      await service.setFollowSystemBrightness(true);

      expect(service.state.followSystemBrightness, isTrue);
    });

    test('reset() clears followSystemBrightness back to false', () async {
      final service = await makeService(
        seed: {'antgrid.follow_system_brightness.v1': true},
      );
      expect(service.state.followSystemBrightness, isTrue);

      await service.reset();

      expect(service.state.followSystemBrightness, isFalse);
    });
  });
}
