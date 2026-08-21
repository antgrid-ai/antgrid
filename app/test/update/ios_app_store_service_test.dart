import 'dart:convert';

import 'package:antgrid/update/ios_app_store_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Exercises isUpdateAvailable's fetch/decode/error paths with an injected
// MockClient and mocked PackageInfo; the pure reply interpretation is covered
// separately in ios_app_store_decision_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'antgrid',
      packageName: 'ai.radhaai.antgrid',
      version: '1.0.6',
      buildNumber: '7',
      buildSignature: '',
      installerStore: null,
    );
  });

  IosAppStoreUpdateService service(
    MockClient client, {
    String? systemVersion = '18.5',
  }) => IosAppStoreUpdateService(
    httpClient: client,
    systemVersion: () async => systemVersion,
  );

  String lookupBody({String version = '1.0.7', String? minimumOsVersion}) =>
      jsonEncode({
        'resultCount': 1,
        'results': [
          {
            'version': version,
            'trackViewUrl': 'https://apps.apple.com/app/id123',
            'minimumOsVersion': ?minimumOsVersion,
          },
        ],
      });

  test(
    'newer listing → true, and the listing URL is cached for the row',
    () async {
      final client = MockClient((req) async {
        expect(req.url.host, IosAppStoreUpdateService.lookupAuthority);
        expect(req.url.path, IosAppStoreUpdateService.lookupPath);
        expect(req.url.queryParameters['bundleId'], 'ai.radhaai.antgrid');
        return http.Response(lookupBody(), 200);
      });
      final s = service(client);
      expect(s.listingUrl, isNull);
      expect(await s.isUpdateAvailable(), isTrue);
      expect(s.listingUrl, 'https://apps.apple.com/app/id123');
    },
  );

  test('same version → false, listing URL stays unset', () async {
    final client = MockClient(
      (_) async => http.Response(lookupBody(version: '1.0.6'), 200),
    );
    final s = service(client);
    expect(await s.isUpdateAvailable(), isFalse);
    expect(s.listingUrl, isNull);
  });

  test('unpublished app (empty results) → false', () async {
    final client = MockClient(
      (_) async =>
          http.Response(jsonEncode({'resultCount': 0, 'results': []}), 200),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });

  test('listing needs a newer OS than the device → false', () async {
    final client = MockClient(
      (_) async => http.Response(lookupBody(minimumOsVersion: '19.0'), 200),
    );
    expect(
      await service(client, systemVersion: '18.5').isUpdateAvailable(),
      isFalse,
    );
  });

  test('unknown device OS fails open → true', () async {
    final client = MockClient(
      (_) async => http.Response(lookupBody(minimumOsVersion: '19.0'), 200),
    );
    expect(
      await service(client, systemVersion: null).isUpdateAvailable(),
      isTrue,
    );
  });

  test('non-200 → false', () async {
    final client = MockClient(
      (_) async => http.Response('service unavailable', 503),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });

  test('malformed body → false', () async {
    final client = MockClient(
      (_) async => http.Response('<!doctype html>not json', 200),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });

  test('network failure → false', () async {
    final client = MockClient(
      (_) async => throw http.ClientException('connection refused'),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });
}
