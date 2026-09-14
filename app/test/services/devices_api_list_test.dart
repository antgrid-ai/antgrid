import 'dart:convert';

import 'package:antgrid/services/devices_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

DevicesApi _api(MockClient client, {String? cookie = 'session=abc'}) =>
    DevicesApi(
      licenseApiUrl: 'https://lic.test',
      cookieProvider: () async => cookie,
      httpClient: client,
    );

void main() {
  group('DevicesApi.list', () {
    test('returns the account rows on 200', () async {
      final api = _api(
        MockClient(
          (_) async => http.Response(
            jsonEncode({
              'devices': [
                {
                  'id': 'row-1',
                  'device_id': 'uuid-1',
                  'kind': 'agent',
                  'platform': 'windows',
                  'display_name': 'Machine A',
                },
              ],
            }),
            200,
          ),
        ),
      );

      final devices = await api.list();
      expect(devices.single.deviceId, 'uuid-1');
    });

    test('an empty account is data, not an error', () async {
      final api = _api(
        MockClient((_) async => http.Response(jsonEncode({'devices': []}), 200)),
      );
      expect(await api.list(), isEmpty);
    });

    // The whole point of the contract: callers prune local state against this
    // result, so a failure that answered `[]` would read as "this account has
    // no devices" and delete every machine's cache.
    for (final status in [401, 403, 500, 502]) {
      test('throws on $status rather than answering empty', () async {
        final api = _api(MockClient((_) async => http.Response('nope', status)));
        await expectLater(api.list(), throwsA(isA<Exception>()));
      });
    }

    test('throws when signed out rather than answering empty', () async {
      var called = false;
      final api = _api(MockClient((_) async {
        called = true;
        return http.Response('{}', 200);
      }), cookie: null);

      await expectLater(api.list(), throwsA(isA<Exception>()));
      expect(called, isFalse, reason: 'no request without a cookie');
    });
  });
}
