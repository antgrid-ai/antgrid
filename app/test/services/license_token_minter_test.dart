import 'dart:async';
import 'dart:convert';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/license_token_minter.dart';

void main() {
  test('failed renewal retries after 30 seconds without another TTL delay', () {
    fakeAsync((clock) {
      var calls = 0;
      final minter = LicenseTokenMinter(
        licenseApiUrl: 'https://api.antgrid.test',
        clientId: 'cid',
        clientSecret: 'secret',
        httpClient: MockClient((_) async {
          if (++calls == 2) throw Exception('offline');
          return http.Response(
            '{"access_token":"fresh","expires_in":3600}',
            200,
          );
        }),
      );
      unawaited(minter.start());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 2880));
      expect(calls, 2);
      clock.elapse(const Duration(seconds: 29));
      expect(calls, 2);
      clock.elapse(const Duration(seconds: 1));
      expect(calls, 3);
      minter.stop();
      clock.elapse(const Duration(hours: 1));
      expect(calls, 3);
    });
  });

  test(
    'timed-out mint can retry and late response cannot replace token',
    () async {
      final delayed = Completer<http.Response>();
      var calls = 0;
      final minter = LicenseTokenMinter(
        licenseApiUrl: 'https://api.antgrid.test',
        clientId: 'cid',
        clientSecret: 'secret',
        requestTimeout: const Duration(milliseconds: 20),
        httpClient: MockClient((_) async {
          if (++calls == 1) return delayed.future;
          return http.Response(
            '{"access_token":"fresh","expires_in":3600}',
            200,
          );
        }),
      );
      await expectLater(minter.mint(), throwsA(isA<TimeoutException>()));
      expect(minter.getToken(), isNull);
      expect(await minter.mint(), 'fresh');
      delayed.complete(
        http.Response('{"access_token":"old","expires_in":3600}', 200),
      );
      await Future<void>.delayed(Duration.zero);
      expect(minter.getToken(), 'fresh');
    },
  );

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

  test(
    '400 invalid_client is terminal and clears a previously cached token',
    () async {
      var calls = 0;
      final minter = LicenseTokenMinter(
        licenseApiUrl: 'https://api.antgrid.test',
        clientId: 'cid',
        clientSecret: 'secret',
        httpClient: MockClient(
          (_) async => ++calls == 1
              ? http.Response('{"access_token":"old","expires_in":3600}', 200)
              : http.Response('{"error":"invalid_client"}', 400),
        ),
      );
      expect(await minter.token(), 'old');
      await expectLater(minter.mint(), throwsA(isA<DeviceRevokedException>()));
      expect(minter.getToken(), isNull);
      await expectLater(minter.token(), throwsA(isA<DeviceRevokedException>()));
      await expectLater(minter.mint(), throwsA(isA<DeviceRevokedException>()));
      expect(calls, 2, reason: 'known revoked credentials must not be retried');
    },
  );

  for (final response in [
    (400, '{"error":"invalid_scope"}'),
    (400, 'invalid_client'),
    (400, '["invalid_client"]'),
    (503, '{"error":"invalid_client"}'),
  ]) {
    test('non-credential error $response is not a revocation', () async {
      final minter = LicenseTokenMinter(
        licenseApiUrl: 'https://api.antgrid.test',
        clientId: 'cid',
        clientSecret: 'secret',
        httpClient: MockClient(
          (_) async => http.Response(response.$2, response.$1),
        ),
      );
      await expectLater(
        minter.mint(),
        throwsA(isNot(isA<DeviceRevokedException>())),
      );
    });
  }

  test('revocation outranks a pending renewal cooldown', () async {
    var calls = 0;
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'secret',
      httpClient: MockClient(
        (_) async => http.Response(
          ++calls == 1 ? 'offline' : '{"error":"invalid_client"}',
          calls == 1 ? 503 : 400,
        ),
      ),
    );
    await expectLater(minter.token(), throwsException);
    await expectLater(minter.mint(), throwsA(isA<DeviceRevokedException>()));
    await expectLater(minter.token(), throwsA(isA<DeviceRevokedException>()));
    expect(calls, 2);
  });

  test('a concurrent mint cannot restore a token after revocation', () async {
    final lateResponse = Completer<http.Response>();
    var calls = 0;
    final minter = LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'secret',
      httpClient: MockClient(
        (_) async => ++calls == 1
            ? lateResponse.future
            : http.Response('{"error":"invalid_client"}', 400),
      ),
    );
    final pending = minter.token();
    final rejected = expectLater(
      pending,
      throwsA(isA<DeviceRevokedException>()),
    );
    await expectLater(minter.mint(), throwsA(isA<DeviceRevokedException>()));
    lateResponse.complete(
      http.Response('{"access_token":"stale","expires_in":3600}', 200),
    );
    await rejected;
    expect(minter.getToken(), isNull);
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

  group('token()', () {
    late int calls;
    late DateTime now;
    late Map<int, int> statusByCall;
    late Map<int, Map<String, String>> headersByCall;
    late int lifetimeSeconds;
    LicenseTokenMinter minter() => LicenseTokenMinter(
      licenseApiUrl: 'https://api.antgrid.test',
      clientId: 'cid',
      clientSecret: 'csec',
      now: () => now,
      httpClient: MockClient((_) async {
        calls++;
        final status = statusByCall[calls];
        if (status != null) {
          return http.Response('', status, headers: headersByCall[calls] ?? {});
        }
        return http.Response(
          jsonEncode({
            'access_token': 'tok-$calls',
            'expires_in': lifetimeSeconds,
          }),
          200,
        );
      }),
    );

    setUp(() {
      calls = 0;
      now = DateTime.utc(2026);
      statusByCall = {};
      headersByCall = {};
      lifetimeSeconds = 100;
    });

    test('reuses the cached token until 80% of its lifetime', () async {
      final m = minter();
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 79));
      expect(await m.token(), 'tok-1');
      expect(calls, 1);
      now = now.add(const Duration(seconds: 1));
      expect(await m.token(), 'tok-2');
      expect(calls, 2);
    });

    test('concurrent callers share one mint', () async {
      final m = minter();
      final a = m.token(), b = m.token();
      expect(await a, 'tok-1');
      expect(await b, 'tok-1');
      expect(calls, 1);
    });

    test('a failed mint waits for cooldown before retrying', () async {
      statusByCall = {1: 500};
      final m = minter();
      await expectLater(m.token(), throwsException);
      await expectLater(m.token(), throwsException);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 65));
      expect(await m.token(), 'tok-2');
    });

    test('a failed renewal falls back to the unexpired token', () async {
      statusByCall = {2: 429, 3: 429};
      final m = minter();
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 80));
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 20));
      await expectLater(m.token(), throwsException);
      expect(calls, 2, reason: 'expiry must not bypass the mint cooldown');
      now = now.add(const Duration(seconds: 45));
      await expectLater(m.token(), throwsException);
      expect(calls, 3);
    });

    test('lease polling reuses the token during renewal cooldown', () async {
      lifetimeSeconds = 3600;
      statusByCall = {2: 500};
      final m = minter();
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 2880));
      expect(await m.token(), 'tok-1');
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(seconds: 20));
        expect(await m.token(), 'tok-1');
        expect(calls, 2);
      }
      now = now.add(const Duration(seconds: 5));
      expect(await m.token(), 'tok-3');
      expect(calls, 3);
    });

    test('renewal backoff grows and resets after success', () async {
      lifetimeSeconds = 3600;
      statusByCall = {2: 500, 3: 500, 5: 500};
      final m = minter();
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 2880));
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 65));
      expect(await m.token(), 'tok-1');
      expect(calls, 3);
      now = now.add(const Duration(seconds: 129));
      expect(await m.token(), 'tok-1');
      expect(calls, 3);
      now = now.add(const Duration(seconds: 1));
      expect(await m.token(), 'tok-4');
      now = now.add(const Duration(seconds: 2880));
      expect(await m.token(), 'tok-4');
      now = now.add(const Duration(seconds: 65));
      expect(await m.token(), 'tok-6');
    });

    for (final header in ['x-retry-after', 'retry-after']) {
      test('renewal honors $header on a rate limit', () async {
        lifetimeSeconds = 3600;
        statusByCall = {2: 429};
        headersByCall = {
          2: {header: '150'},
        };
        final m = minter();
        expect(await m.token(), 'tok-1');
        now = now.add(const Duration(seconds: 2880));
        expect(await m.token(), 'tok-1');
        now = now.add(const Duration(seconds: 149));
        expect(await m.token(), 'tok-1');
        expect(calls, 2);
        now = now.add(const Duration(seconds: 1));
        expect(await m.token(), 'tok-3');
      });
    }

    test('rejecting a fallback cannot bypass renewal cooldown', () async {
      statusByCall = {2: 429};
      final m = minter();
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 80));
      expect(await m.token(), 'tok-1');
      expect(m.discard('tok-1'), isTrue);
      await expectLater(m.token(), throwsException);
      expect(calls, 2);
      now = now.add(const Duration(seconds: 65));
      expect(await m.token(), 'tok-3');
    });

    test('a revoked device is not masked by the cached token', () async {
      statusByCall = {2: 401};
      final m = minter();
      expect(await m.token(), 'tok-1');
      now = now.add(const Duration(seconds: 80));
      await expectLater(m.token(), throwsA(isA<DeviceRevokedException>()));
    });

    test('discard forgets only the token it names', () async {
      final m = minter();
      expect(await m.token(), 'tok-1');
      m.discard('tok-0');
      expect(await m.token(), 'tok-1');
      m.discard('tok-1');
      expect(await m.token(), 'tok-2');
      expect(calls, 2);
    });

    test('discard reports whether a retry could help', () async {
      final m = minter();
      expect(await m.token(), 'tok-1');
      expect(m.discard('tok-1'), isFalse, reason: 'fresh from a mint');
      expect(await m.token(), 'tok-2');
      expect(await m.token(), 'tok-2');
      expect(m.discard('tok-2'), isTrue, reason: 'reused from the cache');
    });
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
