import 'dart:convert';

import 'package:antgrid/update/github_release_update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';

// Exercises isUpdateAvailable's fetch/decode/error paths with an injected
// MockClient and mocked PackageInfo; the pure version comparison is covered
// separately in version_compare_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'antgrid',
      packageName: 'com.antgrid.app',
      version: '1.0.6',
      buildNumber: '7',
      buildSignature: '',
      installerStore: null,
    );
  });

  GithubReleaseUpdateService service(MockClient client) =>
      GithubReleaseUpdateService(httpClient: client);

  test('newer latest release → true', () async {
    final client = MockClient((req) async {
      expect(req.url.toString(), GithubReleaseUpdateService.latestReleaseUrl);
      expect(req.headers['Accept'], 'application/vnd.github+json');
      return http.Response(jsonEncode({'tag_name': 'v1.0.7'}), 200);
    });
    expect(await service(client).isUpdateAvailable(), isTrue);
  });

  test('same version → false', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'tag_name': 'v1.0.6'}), 200),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });

  test('non-200 (rate-limited) → false', () async {
    final client = MockClient(
      (_) async => http.Response('rate limit exceeded', 403),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });

  test('malformed body → false', () async {
    final client = MockClient(
      (_) async => http.Response('<!doctype html>not json', 200),
    );
    expect(await service(client).isUpdateAvailable(), isFalse);
  });

  test('missing tag_name → false', () async {
    final client = MockClient(
      (_) async => http.Response(jsonEncode({'name': 'v1.0.7'}), 200),
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
