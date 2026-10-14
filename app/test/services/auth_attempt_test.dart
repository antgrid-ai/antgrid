import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/auth_service.dart';

class MemoryAuthStorage implements AuthStorage {
  String? cookie;
  String? pending;
  Completer<void>? writeGate;
  Completer<void>? writing;
  Completer<void>? clearGate;
  Completer<void>? clearing;
  bool refuse = false;
  @override
  Future<String?> readCookie() async => cookie;
  @override
  Future<void> writeCookie(String value) async {
    writing?.complete();
    if (writeGate != null) await writeGate!.future;
    if (refuse) throw Exception('keychain unavailable');
    cookie = value;
  }

  @override
  Future<void> clearCookie() async {
    cookie = null;
  }

  @override
  Future<String?> readPendingSignIn() async => pending;
  @override
  Future<void> writePendingSignIn(String value) async {
    if (refuse) throw Exception('keychain unavailable');
    pending = value;
  }

  @override
  Future<void> clearPendingSignIn() async {
    clearing?.complete();
    if (clearGate != null) await clearGate!.future;
    pending = null;
  }
}

void main() {
  final now = DateTime.utc(2026, 10, 5);
  http.Response nativeReceipt() => http.Response(
    jsonEncode({
      'id': 'flow-1',
      'journeyId': 'journey-1',
      'serverTime': now.toIso8601String(),
      'expiresAt': now.add(kMagicLinkWindow).toIso8601String(),
      'url': 'https://lic.test/oauth/start?flow=flow-1&launch=opaque',
    }),
    200,
  );
  AuthService native(
    MemoryAuthStorage storage, {
    int status = 200,
    List<http.Request>? requests,
  }) => AuthService(
    licenseApiUrl: 'https://lic.test',
    storage: storage,
    now: () => now,
    launchUrl: (_) async => true,
    httpClient: MockClient((req) async {
      requests?.add(req);
      if (req.url.path.endsWith('/native/start')) return nativeReceipt();
      return http.Response(
        '{}',
        status,
        headers: status == 200
            ? {
                'set-cookie':
                    '__Secure-better-auth.session_token=signed.session; Path=/',
              }
            : {},
      );
    }),
  );
  final callback = Uri.parse(
    'antgrid://auth/callback?flow=flow-1&code=opaque-code',
  );

  for (final status in [429, 503]) {
    test(
      'failed magic resend HTTP $status preserves the original flow',
      () async {
        final storage = MemoryAuthStorage();
        var starts = 0;
        final auth = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          now: () => now,
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/start')) {
              if (++starts > 1) return http.Response('{}', status);
              return http.Response(
                jsonEncode({
                  'id': 'magic-1',
                  'journeyId': 'journey-1',
                  'serverTime': now.toIso8601String(),
                  'expiresAt': now.add(kMagicLinkWindow).toIso8601String(),
                  'retryAt': now.toIso8601String(),
                }),
                200,
                headers: {
                  'set-cookie': 'antgrid.cross_device_token.magic-1=bind',
                },
              );
            }
            return http.Response('{"status":"pending"}', 200);
          }),
        );
        final original = await auth.startMagicLink('owner@example.com');
        final stored = storage.pending;
        await expectLater(
          auth.startMagicLink('owner@example.com', previous: original),
          throwsA(isA<AuthException>()),
        );
        expect(storage.pending, stored);
        expect(
          (await auth.pollStatus(original)).status,
          MagicLinkStatus.pending,
        );
      },
    );
  }

  test(
    'an in-flight old poll cannot discard pending storage during resend',
    () async {
      final storage = MemoryAuthStorage();
      final oldPoll = Completer<http.Response>();
      final resend = Completer<http.Response>();
      var starts = 0;
      final auth = AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        now: () => now,
        httpClient: MockClient((req) async {
          if (req.url.path.endsWith('/status')) return oldPoll.future;
          if (++starts > 1) return resend.future;
          return http.Response(
            jsonEncode({
              'id': 'magic-1',
              'journeyId': 'journey-1',
              'serverTime': now.toIso8601String(),
              'expiresAt': now.add(kMagicLinkWindow).toIso8601String(),
              'retryAt': now.toIso8601String(),
            }),
            200,
            headers: {'set-cookie': 'antgrid.cross_device_token.magic-1=bind'},
          );
        }),
      );
      final original = await auth.startMagicLink('owner@example.com');
      final stored = storage.pending;
      final polling = auth.pollStatus(original);
      final sending = auth.startMagicLink(
        'owner@example.com',
        previous: original,
      );
      oldPoll.complete(http.Response('{"status":"expired"}', 200));
      expect((await polling).status, MagicLinkStatus.error);
      expect(storage.pending, stored);
      resend.complete(http.Response('{}', 503));
      await expectLater(sending, throwsA(isA<AuthException>()));
      expect(storage.pending, stored);
    },
  );

  test(
    'native OAuth sends S256, persists the verifier, redeems through the dedicated endpoint',
    () async {
      final storage = MemoryAuthStorage();
      final requests = <http.Request>[];
      final auth = native(storage, requests: requests);
      expect(await auth.startOAuth('github'), OAuthStart.handedOff);
      final record = jsonDecode(storage.pending!) as Map<String, dynamic>;
      final start = jsonDecode(requests.first.body) as Map<String, dynamic>;
      expect(start['challenge'], isNot(record['verifier']));
      expect((start['challenge'] as String).length, 43);
      expect(await auth.handleDeepLink(callback), isTrue);
      expect(requests.last.url.path, '/api/auth/sign-in/native/redeem');
      expect(jsonDecode(requests.last.body)['verifier'], record['verifier']);
      expect(
        storage.cookie,
        '__Secure-better-auth.session_token=signed.session',
      );
      expect(storage.pending, isNull);
    },
  );

  test(
    'unsolicited, malformed, stale and cancelled callbacks cannot authenticate',
    () async {
      final storage = MemoryAuthStorage();
      final requests = <http.Request>[];
      final auth = native(storage, requests: requests);
      expect(await auth.handleDeepLink(callback), isFalse);
      expect(requests, isEmpty);
      await auth.startOAuth('github');
      for (final link in [
        'antgrid://auth/wrong?flow=flow-1&code=x',
        'antgrid://auth:80/callback?flow=flow-1&code=x',
        'antgrid://auth/callback?flow=other&code=x',
        'antgrid://auth/callback?flow=flow-1&code=%80',
        'antgrid://auth/callback?flow=flow-1&code=x&code=y',
        'antgrid://auth/callback?flow=flow-1&code=x&error=cancelled',
        'antgrid://auth/callback?flow=flow-1&code=x&unexpected=value',
      ]) {
        expect(await auth.handleDeepLink(Uri.parse(link)), isFalse);
      }
      await auth.cancelAuthentication();
      expect(await auth.handleDeepLink(callback), isFalse);
      expect(storage.cookie, isNull);
      expect(requests.length, 1);
    },
  );

  test(
    'cold-start native handoff restores the verifier; expired attempts are ignored',
    () async {
      final storage = MemoryAuthStorage();
      await native(storage).startOAuth('google');
      final restored = native(storage);
      expect(await restored.handleDeepLink(callback), isTrue);
      final expired = MemoryAuthStorage()
        ..pending = jsonEncode({
          'kind': 'oauth',
          'id': 'flow-1',
          'verifier': 'secret',
          'expiresAt': now
              .subtract(const Duration(seconds: 1))
              .toIso8601String(),
        });
      expect(await native(expired).handleDeepLink(callback), isFalse);
    },
  );

  test(
    'an old callback finishing cleanup cannot clear a newer OAuth attempt',
    () async {
      final storage = MemoryAuthStorage();
      final auth = native(storage);
      await auth.startOAuth('github');
      storage.clearing = Completer<void>();
      storage.clearGate = Completer<void>();
      final old = auth.handleDeepLink(callback);
      await storage.clearing!.future;
      final next = auth.startOAuth('google');
      storage.clearing = null;
      storage.clearGate!.complete();
      expect(await old, isFalse);
      expect(await next, OAuthStart.handedOff);
      expect(await auth.handleDeepLink(callback), isTrue);
      expect(storage.cookie, isNotNull);
    },
  );

  test(
    'cancellation during a storage write removes stale credentials and preserves the newer attempt',
    () async {
      final storage = MemoryAuthStorage()
        ..writing = Completer<void>()
        ..writeGate = Completer<void>();
      final auth = native(storage);
      await auth.startOAuth('github');
      final old = auth.handleDeepLink(callback);
      await storage.writing!.future;
      final cancelled = auth.cancelAuthentication();
      final next = auth.signInWithPassword(
        email: 'owner@example.com',
        password: 'password',
      );
      storage.writing = null;
      storage.writeGate!.complete();
      expect(await old, isFalse);
      await cancelled;
      expect(await next, PasswordSignIn.ok);
      expect(storage.cookie, isNotNull);
    },
  );

  for (final status in [429, 503]) {
    test(
      'verification and reset reject HTTP $status with typed errors and retry timing',
      () async {
        final auth = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: MemoryAuthStorage(),
          httpClient: MockClient(
            (_) async =>
                http.Response('{}', status, headers: {'retry-after': '93'}),
          ),
        );
        for (final request in [
          auth.sendVerificationEmail,
          auth.requestPasswordReset,
        ]) {
          await expectLater(
            request('owner@example.com'),
            throwsA(
              isA<AuthException>().having(
                (e) => e.kind,
                'kind',
                status == 429 ? AuthFailure.throttled : AuthFailure.unavailable,
              ),
            ),
          );
        }
      },
    );
  }

  test(
    'secure-storage failures are typed and never report authentication success',
    () async {
      final storage = MemoryAuthStorage()..refuse = true;
      await expectLater(
        native(storage).startOAuth('github'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.kind,
            'kind',
            AuthFailure.storage,
          ),
        ),
      );
      await expectLater(
        native(
          storage,
        ).signInWithPassword(email: 'owner@example.com', password: 'password'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.kind,
            'kind',
            AuthFailure.storage,
          ),
        ),
      );
      expect(storage.cookie, isNull);
    },
  );
}
