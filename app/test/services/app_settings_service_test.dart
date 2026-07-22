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
}
