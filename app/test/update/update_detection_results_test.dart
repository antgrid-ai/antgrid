import 'dart:async';
import 'dart:convert';

import 'package:antgrid/update/github_release_update_service.dart';
import 'package:antgrid/update/ios_app_store_update_service.dart';
import 'package:antgrid/update/macos_appcast_update_service.dart';
import 'package:antgrid/update/update_check_result.dart';
import 'package:antgrid/update/update_strategy.dart';
import 'package:antgrid/update/windows_store_update_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => PackageInfo.setMockInitialValues(
      appName: 'antgrid',
      packageName: 'ai.antgrid.app',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    ),
  );

  String appcast(String build) =>
      '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
      '<channel><item><sparkle:version>$build</sparkle:version>'
      '<sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>'
      '</item></channel></rss>';
  String listing(String version) => jsonEncode({
    'results': [
      {'version': version, 'trackViewUrl': 'https://apps.apple.com/app/id123'},
    ],
  });

  for (final platform in ['Linux', 'macOS', 'iOS']) {
    UpdateStrategy strategy(MockClient client) => switch (platform) {
      'Linux' => LinuxBrowserStrategy(
        releases: GithubReleaseUpdateService(httpClient: client),
      ),
      'macOS' => MacosSparkleStrategy(
        appcast: MacosAppcastUpdateService(httpClient: client),
      ),
      _ => IosAppStoreStrategy(
        service: IosAppStoreUpdateService(
          httpClient: client,
          systemVersion: () async => '18.0',
        ),
      ),
    };
    String valid(bool newer) => switch (platform) {
      'Linux' => jsonEncode({'tag_name': newer ? 'v2.0.0' : 'v1.0.0'}),
      'macOS' => appcast(newer ? '2' : '1'),
      _ => listing(newer ? '2.0.0' : '1.0.0'),
    };
    for (final newer in [false, true]) {
      test(
        '$platform successful check distinguishes current and available ($newer)',
        () async {
          final s = strategy(
            MockClient((_) async => http.Response(valid(newer), 200)),
          );
          addTearDown(s.dispose);
          final result = await s.detect();
          expect(
            result.status,
            newer ? UpdateCheckStatus.available : UpdateCheckStatus.upToDate,
          );
          if (newer) {
            expect(result.version, '2.0.0');
            expect(result.candidateId, isNotNull);
            expect(s.pendingVersion, '2.0.0');
          }
        },
      );
    }
    for (final failure in [
      'malformed',
      'missing',
      'bad version',
      'offline',
      'timeout',
      'HTTP',
    ]) {
      test('$platform $failure is a failed check, never up to date', () async {
        final client = MockClient((_) async {
          if (failure == 'offline') throw http.ClientException('offline');
          if (failure == 'timeout') throw TimeoutException('timed out');
          if (failure == 'HTTP') return http.Response('unavailable', 503);
          if (failure == 'bad version') {
            return http.Response(switch (platform) {
              'Linux' => jsonEncode({'tag_name': 'broken'}),
              'macOS' => appcast('broken'),
              _ => listing('broken'),
            }, 200);
          }
          return http.Response(failure == 'missing' ? '{}' : 'not a feed', 200);
        });
        final s = strategy(client);
        addTearDown(s.dispose);
        expect((await s.detect()).status, UpdateCheckStatus.failed);
      });
    }
    test('$platform failure preserves the pending version', () async {
      var fail = false;
      final s = strategy(
        MockClient(
          (_) async => http.Response(
            fail ? 'unavailable' : valid(true),
            fail ? 503 : 200,
          ),
        ),
      );
      addTearDown(s.dispose);
      await s.detect();
      fail = true;
      expect((await s.detect()).status, UpdateCheckStatus.failed);
      expect(s.pendingVersion, '2.0.0');
    });
  }

  test('unpublished iOS storefront is unsupported', () async {
    final service = IosAppStoreUpdateService(
      httpClient: MockClient((_) async => http.Response('{"results":[]}', 200)),
      systemVersion: () async => '18',
    );
    expect((await service.check()).status, UpdateCheckStatus.unsupported);
  });

  for (final failure in ['malformed', 'offline', 'timeout', 'unsupported']) {
    test('Android $failure never claims up to date or starts a flow', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('de.ffuf.in_app_update/methods');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (failure == 'malformed') return {};
        if (failure == 'timeout') throw TimeoutException('store timeout');
        throw PlatformException(
          code: 'TASK_FAILURE',
          message: failure == 'unsupported'
              ? 'Install Error(-10): APP_NOT_OWNED'
              : 'offline',
        );
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final strategy = PlayUpdateStrategy();
      addTearDown(strategy.dispose);
      expect(
        (await strategy.detect()).status,
        failure == 'unsupported'
            ? UpdateCheckStatus.unsupported
            : UpdateCheckStatus.failed,
      );
      expect(calls, ['checkForUpdate']);
    });
  }

  for (final reply in [
    null,
    {},
    {'updateCount': -1},
    {'updateCount': 1},
  ]) {
    test('malformed Store metadata ($reply) is failed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('antgrid/store_update');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => reply);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(
        (await const WindowsStoreUpdateService().checkForUpdates()).check,
        StoreUpdateCheck.failed,
      );
    });
  }
  for (final error in [
    PlatformException(code: 'store_unavailable', message: 'offline'),
    TimeoutException('Store timeout'),
  ]) {
    test(
      'Store failures ($error) offer Retry rather than unsupported',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const channel = MethodChannel('antgrid/store_update');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (_) async => throw error);
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        expect(
          (await const WindowsStoreUpdateService().checkForUpdates()).check,
          StoreUpdateCheck.failed,
        );
      },
    );
  }
}
