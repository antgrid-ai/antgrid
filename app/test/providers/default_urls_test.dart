import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/config/environment.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/services/app_settings_service.dart';

import '../helpers/prefs_test_mock.dart';

/// These run under `flutter test`, i.e. a non-release build, so the build-mode
/// default resolves to the staging environment. The release/prod branch is a
/// compile-time const and can't be exercised here — it's verified by reading
/// [AppEnvironment] in a release smoke build.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('test run is non-release (build-mode default = staging)', () {
    expect(kReleaseMode, isFalse);
  });

  group('AppEnvironment build-mode defaults', () {
    test('staging URLs in debug/profile builds', () {
      expect(AppEnvironment.relayUrl, 'wss://relay.staging.antgrid.ai');
      expect(AppEnvironment.licenseApiUrl, 'https://app.staging.antgrid.ai');
    });
  });

  group('defaultRelayUrlProvider', () {
    Future<ProviderContainer> containerWith(
      Map<String, Object> prefsValues,
    ) async {
      useInMemoryPrefs(prefsValues);
      final prefs = await openAppSettingsPrefs();
      final container = ProviderContainer(
        overrides: [
          appSettingsServiceProvider.overrideWith(
            () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'falls back to the build-mode default when no settings override',
      () async {
        final container = await containerWith({});
        expect(
          container.read(defaultRelayUrlProvider),
          AppEnvironment.relayUrl,
        );
      },
    );

    test('App Settings value wins over the default', () async {
      final container = await containerWith({
        'app.defaultRelayUrl': 'ws://custom:9999',
      });
      expect(container.read(defaultRelayUrlProvider), 'ws://custom:9999');
    });

    test('empty App Settings value falls through to the default', () async {
      final container = await containerWith({'app.defaultRelayUrl': ''});
      expect(container.read(defaultRelayUrlProvider), AppEnvironment.relayUrl);
    });
  });

  group('licenseApiUrlProvider', () {
    test('falls back to the build-mode default with no dart-define', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(
        container.read(licenseApiUrlProvider),
        AppEnvironment.licenseApiUrl,
      );
    });
  });
}
