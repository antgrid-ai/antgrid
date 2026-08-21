import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('telemetryEnabled defaults to true and persists when toggled', () async {
    useInMemoryPrefs();
    final prefs = await openAppSettingsPrefs();
    final seed = AppSettings.fromPrefs(prefs);
    expect(seed.telemetryEnabled, isTrue);

    final container = ProviderContainer(
      overrides: [
        appSettingsServiceProvider.overrideWith(
          () => AppSettingsService(prefs, seed),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(appSettingsServiceProvider.notifier)
        .setTelemetryEnabled(false);
    expect(
      container.read(appSettingsServiceProvider).telemetryEnabled,
      isFalse,
    );

    // A fresh read of prefs reflects the persisted value.
    expect(AppSettings.fromPrefs(prefs).telemetryEnabled, isFalse);
  });
}
