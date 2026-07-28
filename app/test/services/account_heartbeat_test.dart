import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/account_heartbeat.dart';

void main() {
  test('POSTs deviceUuid-only body with a Bearer token', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response('', 200);
    });

    final ok = await sendAccountHeartbeat(
      licenseApiUrl: 'https://api.antgrid.test',
      token: 'test-token',
      deviceUuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      httpClient: client,
    );

    expect(ok, isTrue);
    expect(
      captured.url.toString(),
      'https://api.antgrid.test/account/devices/me/heartbeat',
    );
    expect(captured.method, 'POST');
    expect(captured.headers['authorization'], 'Bearer test-token');
    expect(captured.headers['content-type'], contains('application/json'));
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body, {'deviceUuid': 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'});
  });

  test('strips a trailing slash from licenseApiUrl', () async {
    late Uri capturedUri;
    final client = MockClient((req) async {
      capturedUri = req.url;
      return http.Response('', 200);
    });

    await sendAccountHeartbeat(
      licenseApiUrl: 'https://api.antgrid.test/',
      token: 'tok',
      deviceUuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      httpClient: client,
    );

    expect(
      capturedUri.toString(),
      'https://api.antgrid.test/account/devices/me/heartbeat',
    );
  });

  test('returns false on non-2xx response', () async {
    final client = MockClient((req) async => http.Response('', 404));
    final ok = await sendAccountHeartbeat(
      licenseApiUrl: 'https://api.antgrid.test',
      token: 'tok',
      deviceUuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      httpClient: client,
    );
    expect(ok, isFalse);
  });

  test('returns false on network error', () async {
    final client = MockClient((req) async => throw Exception('network failure'));
    final ok = await sendAccountHeartbeat(
      licenseApiUrl: 'https://api.antgrid.test',
      token: 'tok',
      deviceUuid: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
      httpClient: client,
    );
    expect(ok, isFalse);
  });
}
