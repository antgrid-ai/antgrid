import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/license_token_minter.dart';

void main() {
  test(
    'mint() POSTs client_credentials form and returns access_token',
    () async {
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          jsonEncode({'access_token': 'tok-abc', 'expires_in': 3600}),
          200,
          headers: {'content-type': 'application/json'},
        );
      });

      final minter = LicenseTokenMinter(
        licenseApiUrl: 'https://api.antgrid.test',
        clientId: 'cid',
        clientSecret: 'csec',
        httpClient: client,
      );

      final token = await minter.mint();

      expect(token, 'tok-abc');
      expect(
        captured.url.toString(),
        'https://api.antgrid.test/api/auth/oauth2/token',
      );
      expect(captured.method, 'POST');
      expect(
        captured.headers['content-type'],
        contains('application/x-www-form-urlencoded'),
      );
      expect(
        captured.headers['authorization'],
        'Basic ${base64Encode(utf8.encode('cid:csec'))}',
      );
      final body = Uri.splitQueryString(captured.body);
      expect(body['grant_type'], 'client_credentials');
      expect(body['scope'], 'agent');
      expect(body['resource'], 'https://api.antgrid.test/api/auth');
    },
  );

  test('mint() throws DeviceRevokedException on 401', () async {
    final client = MockClient((req) async {
      return http.Response('{"error":"invalid_client"}', 401);
    });
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'bad',
      httpClient: client,
    );
    expect(minter.mint(), throwsA(isA<DeviceRevokedException>()));
  });

  test('mint() throws on malformed body (no access_token)', () async {
    final client = MockClient((req) async {
      return http.Response(
        '{"expires_in":3600}',
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
      httpClient: client,
    );
    expect(
      minter.mint(),
      throwsA(
        isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('malformed'),
        ),
      ),
    );
  });

  test('getToken() returns null before first successful mint', () {
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
    );
    expect(minter.getToken(), isNull);
  });

  test('getToken() returns latest minted token after success', () async {
    var callCount = 0;
    final client = MockClient((req) async {
      callCount++;
      return http.Response(
        jsonEncode({'access_token': 'tok-$callCount', 'expires_in': 3600}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
      httpClient: client,
    );
    await minter.mint();
    expect(minter.getToken(), 'tok-1');
    await minter.mint();
    expect(minter.getToken(), 'tok-2');
  });

  test('start() schedules re-mint at 80% TTL', () async {
    var callCount = 0;
    final client = MockClient((req) async {
      callCount++;
      // 1s TTL so 80% = 800ms; test waits 1.2s.
      return http.Response(
        jsonEncode({'access_token': 'tok-$callCount', 'expires_in': 1}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
      httpClient: client,
    );
    await minter.start();
    expect(callCount, 1);
    expect(minter.getToken(), 'tok-1');

    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(
      callCount,
      greaterThanOrEqualTo(2),
      reason: 'minter should have re-minted at ~800ms',
    );
    minter.stop();
  });

  test('stop() cancels pending refresh', () async {
    var callCount = 0;
    final client = MockClient((req) async {
      callCount++;
      return http.Response(
        jsonEncode({'access_token': 'tok-$callCount', 'expires_in': 1}),
        200,
      );
    });
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
      httpClient: client,
    );
    await minter.start();
    minter.stop();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    expect(callCount, 1, reason: 'no refresh should fire after stop()');
  });
}
