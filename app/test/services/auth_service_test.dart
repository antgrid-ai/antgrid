import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/auth_service.dart';

class _InMemoryStorage implements AuthStorage {
  String? _cookie;
  String? _pending;
  @override
  Future<String?> readCookie() async => _cookie;
  @override
  Future<void> writeCookie(String value) async {
    _cookie = value;
  }

  @override
  Future<void> clearCookie() async {
    _cookie = null;
  }

  @override
  Future<String?> readPendingSignIn() async => _pending;
  @override
  Future<void> writePendingSignIn(String v) async {
    _pending = v;
  }

  @override
  Future<void> clearPendingSignIn() async {
    _pending = null;
  }
}

/// Stands in for a keychain that is unreadable on the device.
class _ThrowingStorage implements AuthStorage {
  Never _fail() => throw Exception('keychain');
  @override
  Future<String?> readCookie() async => _fail();
  @override
  Future<void> writeCookie(String v) async => _fail();
  @override
  Future<void> clearCookie() async => _fail();
  @override
  Future<String?> readPendingSignIn() async => _fail();
  @override
  Future<void> writePendingSignIn(String v) async => _fail();
  @override
  Future<void> clearPendingSignIn() async => _fail();
}

/// Stands in for a keychain that reads fine but refuses to write.
class _WriteFailingStorage extends _InMemoryStorage {
  @override
  Future<void> writePendingSignIn(String v) async =>
      throw Exception('keychain');
}

/// Stands in for a keychain that serves and stores entries but fails to delete
/// them — the one failure mode that can strike a poll AFTER the session cookie
/// has already been written.
class _ClearFailingStorage extends _InMemoryStorage {
  @override
  Future<void> clearPendingSignIn() async => throw Exception('keychain');
}

void main() {
  group('AuthService', () {
    test('OAuth start URI uses a relative same-origin handoff', () {
      final uri = buildOAuthStartUri(
        licenseApiUrl: 'http://localhost:8787',
        provider: 'google',
      );

      expect(uri.path, '/oauth/start');
      expect(uri.queryParameters['provider'], 'google');
      expect(uri.queryParameters['callbackURL'], '/oauth/handoff');
    });

    test('redeems a one-time token and stores the session cookie', () async {
      final storage = _InMemoryStorage();
      late http.Request captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response(
          '{"session":{}}',
          200,
          headers: {
            'set-cookie':
                'better-auth.session_token=signed.value-123; Path=/; HttpOnly; SameSite=Lax',
          },
        );
      });
      final service = AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        httpClient: client,
      );

      await service.handleDeepLink(
        Uri.parse('antgrid://auth/callback?token=ott-abc'),
      );

      // Redeemed against the OTT verify endpoint with the token in the body.
      expect(
        captured.url.toString(),
        'https://lic.test/api/auth/one-time-token/verify',
      );
      expect(jsonDecode(captured.body)['token'], 'ott-abc');
      // Persisted the full session cookie name=value pair from Set-Cookie
      // (not the OTT), so it can be replayed verbatim.
      expect(
        await storage.readCookie(),
        'better-auth.session_token=signed.value-123',
      );
    });

    test('extracts the value from a production __Secure- prefixed, '
        'multi-cookie Set-Cookie header', () async {
      // In production Better-Auth emits `__Secure-better-auth.session_token`
      // and may set sibling cookies. The session value must still be captured
      // (and not bleed into a neighbouring cookie or an Expires= comma).
      final storage = _InMemoryStorage();
      final client = MockClient((req) async {
        return http.Response(
          '{"session":{}}',
          200,
          headers: {
            'set-cookie':
                'csrf=abc; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/, '
                '__Secure-better-auth.session_token=signed.secure-456; '
                'Path=/; Secure; HttpOnly; SameSite=Lax',
          },
        );
      });
      final service = AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        httpClient: client,
      );
      await service.handleDeepLink(
        Uri.parse('antgrid://auth/callback?token=ott-abc'),
      );
      // The stored pair preserves the production `__Secure-` prefixed name.
      expect(
        await storage.readCookie(),
        '__Secure-better-auth.session_token=signed.secure-456',
      );
    });

    test(
      'swallows a network failure during redemption (never throws)',
      () async {
        // The cold-start deep link runs before runApp(); a thrown network error
        // here would crash app launch. Redemption must fail silently.
        final storage = _InMemoryStorage();
        final client = MockClient((req) async {
          throw http.ClientException('offline');
        });
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: client,
        );
        await service.handleDeepLink(
          Uri.parse('antgrid://auth/callback?token=ott-abc'),
        );
        expect(await storage.readCookie(), isNull);
      },
    );

    test('ignores a deep link with no token', () async {
      final storage = _InMemoryStorage();
      final client = MockClient((req) async {
        fail('should not call the network without a token');
      });
      final service = AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        httpClient: client,
      );
      await service.handleDeepLink(Uri.parse('antgrid://auth/callback'));
      expect(await storage.readCookie(), isNull);
    });

    // `queryParameters` percent-DECODES and throws on an escape that is not
    // valid UTF-8. Any web page can fire this URL, and main() dispatches deep
    // links unawaited, so a throw here is an unhandled async error.
    test('ignores a deep link with an undecodable percent-escape', () async {
      final storage = _InMemoryStorage();
      final client = MockClient((req) async {
        fail('should not call the network for an undecodable link');
      });
      final service = AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        httpClient: client,
      );
      await expectLater(
        service.handleDeepLink(Uri.parse('antgrid://auth/callback?token=%80')),
        completes,
      );
      expect(await storage.readCookie(), isNull);
    });

    group('OAuth failure surfacing', () {
      AuthService make(
        MockClient client, {
        Future<bool> Function(Uri url)? launchUrl,
      }) => AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: _InMemoryStorage(),
        httpClient: client,
        // Never the default in these tests: on desktop `flutter test`
        // registers the real url_launcher Dart plugin, which would open an
        // actual browser on the test machine.
        launchUrl: launchUrl ?? (_) async => false,
      );

      /// Runs [act] with [service]'s oauthFailures collected, then yields the
      /// emitted messages (a microtask turn later — broadcast streams deliver
      /// asynchronously).
      Future<List<String>> failuresDuring(
        AuthService service,
        Future<void> Function() act,
      ) async {
        final messages = <String>[];
        final sub = service.oauthFailures.listen(messages.add);
        await act();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
        return messages;
      }

      test(
        'a ?error= bounce emits a failure without touching the network',
        () async {
          // The handoff redirects errors back as ?error=no_session|server_error;
          // previously the handler dropped them and the user saw nothing.
          final service = make(
            MockClient((req) async => fail('no network call expected')),
          );
          final messages = await failuresDuring(
            service,
            () => service.handleDeepLink(
              Uri.parse('antgrid://auth/callback?error=no_session'),
            ),
          );
          expect(messages, ["Sign-in didn't complete. Try again."]);
        },
      );

      test('failure copy names the provider startOAuth recorded', () async {
        final service = make(
          MockClient((req) async => fail('no network call expected')),
          launchUrl: (_) async => true,
        );
        await service.startOAuth('github');
        final messages = await failuresDuring(
          service,
          () => service.handleDeepLink(
            Uri.parse('antgrid://auth/callback?error=server_error'),
          ),
        );
        expect(messages, ["GitHub sign-in didn't complete. Try again."]);
      });

      test(
        'startOAuth surfaces an unopenable browser as AuthException',
        () async {
          // launchUrl reporting false and launchUrl throwing both mean the same
          // thing to the user: the browser never opened.
          final refused = make(
            MockClient((req) async => fail('no network call expected')),
          );
          await expectLater(
            refused.startOAuth('github'),
            throwsA(isA<AuthException>()),
          );

          final threw = make(
            MockClient((req) async => fail('no network call expected')),
            launchUrl: (_) async => throw Exception('no handler'),
          );
          await expectLater(
            threw.startOAuth('github'),
            throwsA(isA<AuthException>()),
          );
        },
      );

      test('a network failure during redemption emits a failure', () async {
        final service = make(
          MockClient((req) async => throw http.ClientException('off')),
        );
        final messages = await failuresDuring(
          service,
          () => service.handleDeepLink(
            Uri.parse('antgrid://auth/callback?token=ott-abc'),
          ),
        );
        expect(messages, hasLength(1));
      });

      test('a non-200 verify response emits a failure', () async {
        final service = make(MockClient((req) async => http.Response('', 401)));
        final messages = await failuresDuring(
          service,
          () => service.handleDeepLink(
            Uri.parse('antgrid://auth/callback?token=ott-abc'),
          ),
        );
        expect(messages, hasLength(1));
      });

      test('a 200 verify without a session cookie emits a failure', () async {
        final service = make(
          MockClient((req) async => http.Response('{}', 200)),
        );
        final messages = await failuresDuring(
          service,
          () => service.handleDeepLink(
            Uri.parse('antgrid://auth/callback?token=ott-abc'),
          ),
        );
        expect(messages, hasLength(1));
      });

      test('a successful redemption emits nothing', () async {
        final service = make(
          MockClient(
            (req) async => http.Response(
              '{"session":{}}',
              200,
              headers: {
                'set-cookie': 'better-auth.session_token=signed.ok; Path=/',
              },
            ),
          ),
        );
        final messages = await failuresDuring(
          service,
          () => service.handleDeepLink(
            Uri.parse('antgrid://auth/callback?token=ott-abc'),
          ),
        );
        expect(messages, isEmpty);
      });
    });

    test('signOut clears the cookie', () async {
      final storage = _InMemoryStorage();
      await storage.writeCookie('old');
      final service = AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        httpClient: null,
      );
      await service.signOut();
      expect(await storage.readCookie(), isNull);
    });

    group('startMagicLink', () {
      test('posts email, returns id, captures bind cookie', () async {
        late http.Request captured;
        final client = MockClient((req) async {
          captured = req;
          return http.Response(
            jsonEncode({'id': 'row-123'}),
            200,
            headers: {
              'set-cookie':
                  'antgrid.cross_device_token=row-123.tok; Path=/; HttpOnly; '
                  'Expires=Wed, 21 Oct 2026 07:28:00 GMT',
            },
          );
        });
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: client,
        );

        final session = await service.startMagicLink('a@b.com');

        expect(session.id, 'row-123');
        expect(session.bindCookie, 'row-123.tok');
        expect(captured.method, 'POST');
        expect(captured.url.path, '/api/auth/sign-in/cross-device/start');
        expect(jsonDecode(captured.body), {'email': 'a@b.com'});
      });

      test('throws AuthException on non-2xx', () async {
        final client = MockClient((req) async => http.Response('nope', 429));
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: client,
        );
        expect(
          () => service.startMagicLink('a@b.com'),
          throwsA(isA<AuthException>()),
        );
      });

      test(
        'extracts bind cookie even when Set-Cookie folds multiple cookies',
        () async {
          final client = MockClient(
            (req) async => http.Response(
              jsonEncode({'id': 'row-9'}),
              200,
              headers: {
                'set-cookie':
                    'other=xyz; Expires=Wed, 21 Oct 2026 07:28:00 GMT, '
                    'antgrid.cross_device_token=row-9.tok; Path=/; HttpOnly',
              },
            ),
          );
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: _InMemoryStorage(),
            httpClient: client,
          );
          final session = await service.startMagicLink('a@b.com');
          expect(session.bindCookie, 'row-9.tok');
        },
      );

      test('throws AuthException on a 200 with a non-JSON body', () async {
        final client = MockClient(
          (req) async => http.Response(
            'not json',
            200,
            headers: {
              'set-cookie':
                  'antgrid.cross_device_token=row-7.tok; Path=/; HttpOnly',
            },
          ),
        );
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: client,
        );
        expect(
          () => service.startMagicLink('a@b.com'),
          throwsA(isA<AuthException>()),
        );
      });

      test(
        'network failure surfaces as AuthException (not a raw exception)',
        () async {
          final client = MockClient((req) async => throw Exception('offline'));
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: _InMemoryStorage(),
            httpClient: client,
          );
          expect(
            () => service.startMagicLink('a@b.com'),
            throwsA(isA<AuthException>()),
          );
        },
      );
    });

    group('pending sign-in persistence', () {
      // The bind cookie is the only credential that can consume an approval.
      // The user leaves the app to approve the link, so Android is free to kill
      // the process while it is backgrounded; a cookie held only in widget
      // state dies with it and strands the approval with no way to claim it.
      MockClient startClient() => MockClient(
        (req) async => http.Response(
          jsonEncode({'id': 'row-123'}),
          200,
          headers: {
            'set-cookie':
                'antgrid.cross_device_token=row-123.tok; Path=/; HttpOnly',
          },
        ),
      );

      AuthService make(AuthStorage storage, {DateTime Function()? now}) =>
          AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: storage,
            httpClient: startClient(),
            now: now,
          );

      test(
        'startMagicLink persists the session so a relaunch can resume',
        () async {
          final storage = _InMemoryStorage();
          await make(storage).startMagicLink('a@b.com');

          // A second AuthService over the same storage stands in for the
          // relaunched process: it kept nothing in memory.
          final restored = await make(storage).restorePendingMagicLink();

          expect(restored, isNotNull);
          expect(restored!.id, 'row-123');
          expect(restored.bindCookie, 'row-123.tok');
        },
      );

      test(
        'startMagicLink persists the email so a restored screen can name it',
        () async {
          // The pending screen reads "Approve the sign-in link sent to <email>".
          // After a relaunch the text field is empty, so the email has to travel
          // with the ticket or the restored screen renders a blank address.
          final storage = _InMemoryStorage();
          await make(storage).startMagicLink('a@b.com');

          final restored = await make(storage).restorePendingMagicLink();

          expect(restored!.email, 'a@b.com');
        },
      );

      test(
        'restorePendingMagicLink returns null when nothing was started',
        () async {
          expect(
            await make(_InMemoryStorage()).restorePendingMagicLink(),
            isNull,
          );
        },
      );

      test(
        'restorePendingMagicLink drops a session past the link window',
        () async {
          final storage = _InMemoryStorage();
          var now = DateTime.utc(2026, 7, 15, 7, 11);
          final service = make(storage, now: () => now);
          await service.startMagicLink('a@b.com');

          // Inside the server's 10-minute TTL the row is still claimable.
          now = now.add(const Duration(minutes: 9, seconds: 59));
          expect(await service.restorePendingMagicLink(), isNotNull);

          // Past it the row is dead server-side. Restoring would strand the user
          // on a spinner that can only ever resolve to "Link expired".
          now = now.add(const Duration(seconds: 2));
          expect(await service.restorePendingMagicLink(), isNull);
        },
      );

      test('a lapsed session is cleared, not left to rot in storage', () async {
        final storage = _InMemoryStorage();
        var now = DateTime.utc(2026, 7, 15, 7, 11);
        final service = make(storage, now: () => now);
        await service.startMagicLink('a@b.com');
        now = now.add(const Duration(minutes: 11));

        await service.restorePendingMagicLink();

        expect(await storage.readPendingSignIn(), isNull);
      });

      test(
        'a failing secure store does not escape into the launch path',
        () async {
          // SignInScreen.initState restores fire-and-forget, so anything thrown
          // here surfaces as an unhandled async error on app launch. Keychain
          // reads do fail in the wild; degrade to "no pending sign-in" instead.
          expect(
            await make(_ThrowingStorage()).restorePendingMagicLink(),
            isNull,
          );
        },
      );

      test('a corrupt stored session is discarded, not thrown', () async {
        final storage = _InMemoryStorage();
        await storage.writePendingSignIn('not json');
        expect(await make(storage).restorePendingMagicLink(), isNull);
        expect(await storage.readPendingSignIn(), isNull);
      });

      test('a failing secure store does not sink the send-link path', () async {
        // The link is already sent by the time the ticket is written, and
        // SignInScreen only catches AuthException — so a raw store failure
        // escapes and strands the button on "Sending…" forever. Persisting is
        // an optimization for the relaunch case; losing it must not lose the
        // sign-in the user can still complete in this process.
        final session = await make(
          _WriteFailingStorage(),
        ).startMagicLink('a@b.com');

        expect(session.bindCookie, 'row-123.tok');
      });

      test(
        'signOut drops the ticket so it cannot resurrect the session',
        () async {
          // hardSignOut wipes every other piece of replayable material. Left
          // behind, the bind cookie lets SignInScreen restore on the next launch
          // and sign the user back in the moment the old link is approved.
          final storage = _InMemoryStorage();
          final service = make(storage);
          await service.startMagicLink('a@b.com');
          await storage.writeCookie('better-auth.session_token=live');

          await service.signOut();

          expect(await storage.readPendingSignIn(), isNull);
        },
      );

      test('discardPendingMagicLink drops an abandoned ticket', () async {
        // "Use a different email" / a bounced address abandons the link. Left
        // behind, it would resurrect a stale pending screen on next launch.
        final storage = _InMemoryStorage();
        final service = make(storage);
        await service.startMagicLink('a@b.com');

        await service.discardPendingMagicLink();

        expect(await storage.readPendingSignIn(), isNull);
        expect(await service.restorePendingMagicLink(), isNull);
      });

      /// Drives one pollStatus tick against a stored ticket and reports whether
      /// the ticket survived.
      Future<bool> ticketSurvivesPoll(MockClient client) async {
        final storage = _InMemoryStorage();
        await storage.writePendingSignIn('{"id":"r1","bindCookie":"r1.tok"}');
        await AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: client,
        ).pollStatus(MagicLinkSession(id: 'r1', bindCookie: 'r1.tok'));
        return await storage.readPendingSignIn() != null;
      }

      test(
        'pollStatus clears the persisted session once it is ready',
        () async {
          final survived = await ticketSurvivesPoll(
            MockClient(
              (req) async => http.Response(
                jsonEncode({'status': 'ready'}),
                200,
                headers: {'set-cookie': 'better-auth.session_token=sess-abc'},
              ),
            ),
          );
          expect(survived, isFalse);
        },
      );

      test(
        'pollStatus clears the persisted session when the link is dead',
        () async {
          for (final dead in ['expired', 'consumed', 'unbound']) {
            final survived = await ticketSurvivesPoll(
              MockClient(
                (req) async => http.Response(jsonEncode({'status': dead}), 200),
              ),
            );
            expect(survived, isFalse, reason: dead);
          }
        },
      );

      test('pollStatus keeps the persisted session while pending', () async {
        final survived = await ticketSurvivesPoll(
          MockClient(
            (req) async =>
                http.Response(jsonEncode({'status': 'pending'}), 200),
          ),
        );
        expect(survived, isTrue);
      });

      test(
        'pollStatus keeps the persisted session on a transient error',
        () async {
          // The approval may still be waiting; a flaky network must not throw
          // away the only credential that can claim it.
          final survived = await ticketSurvivesPoll(
            MockClient((req) async => throw Exception('offline')),
          );
          expect(survived, isTrue);
        },
      );

      test(
        'a store that cannot clear still reports a completed sign-in',
        () async {
          // The cookie is written BEFORE the ticket is dropped, so a throwing
          // clear loses a sign-in that already succeeded: pollStatus escapes
          // (its try/catch covers only the request and the decode), so
          // SignInScreen never cancels the poll timer and the screen rides
          // _maxPollTicks out to "Link expired" on top of a live session.
          final storage = _ClearFailingStorage();
          final poll = await AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: storage,
            httpClient: MockClient(
              (req) async => http.Response(
                jsonEncode({'status': 'ready'}),
                200,
                headers: {'set-cookie': 'better-auth.session_token=sess-abc'},
              ),
            ),
          ).pollStatus(MagicLinkSession(id: 'r1', bindCookie: 'r1.tok'));

          expect(poll.status, MagicLinkStatus.ready);
          expect(
            await storage.readCookie(),
            'better-auth.session_token=sess-abc',
          );
        },
      );

      test('a store that cannot clear still reports a dead link', () async {
        // Same hazard on the terminal states: the status is the caller's only
        // signal to stop polling, and dropping the ticket is a cleanup detail
        // it must not be able to fail.
        for (final dead in ['expired', 'consumed', 'unbound']) {
          final poll = await AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: _ClearFailingStorage(),
            httpClient: MockClient(
              (req) async => http.Response(jsonEncode({'status': dead}), 200),
            ),
          ).pollStatus(MagicLinkSession(id: 'r1', bindCookie: 'r1.tok'));

          expect(poll.status, isNot(MagicLinkStatus.error), reason: dead);
        }
      });
    });

    group('pollStatus', () {
      AuthService make(MockClient client, AuthStorage storage) => AuthService(
        licenseApiUrl: 'https://lic.test',
        storage: storage,
        httpClient: client,
      );
      final session = MagicLinkSession(id: 'r1', bindCookie: 'r1.tok');

      test('sends bind cookie and maps pending', () async {
        late http.Request captured;
        final client = MockClient((req) async {
          captured = req;
          return http.Response(jsonEncode({'status': 'pending'}), 200);
        });
        final poll = await make(client, _InMemoryStorage()).pollStatus(session);
        expect(poll.status, MagicLinkStatus.pending);
        expect(captured.url.path, '/api/auth/sign-in/cross-device/status');
        expect(captured.headers['cookie'], 'antgrid.cross_device_token=r1.tok');
      });

      test('ready writes the session cookie and returns ready', () async {
        final storage = _InMemoryStorage();
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({'status': 'ready'}),
            200,
            headers: {
              'set-cookie':
                  'better-auth.session_token=sess-abc; Path=/; HttpOnly; '
                  'Expires=Wed, 21 Oct 2026 07:28:00 GMT',
            },
          ),
        );
        final poll = await make(client, storage).pollStatus(session);
        expect(poll.status, MagicLinkStatus.ready);
        expect(
          await storage.readCookie(),
          'better-auth.session_token=sess-abc',
        );
      });

      test(
        'ready captures a production __Secure- prefixed session cookie',
        () async {
          // In production Better-Auth emits `__Secure-better-auth.session_token`
          // and may fold sibling cookies (with comma-bearing Expires dates) into
          // one header. The session value must still be captured.
          final storage = _InMemoryStorage();
          final client = MockClient(
            (req) async => http.Response(
              jsonEncode({'status': 'ready'}),
              200,
              headers: {
                'set-cookie':
                    'csrf=abc; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/, '
                    '__Secure-better-auth.session_token=sess-secure; '
                    'Path=/; Secure; HttpOnly',
              },
            ),
          );
          final poll = await make(client, storage).pollStatus(session);
          expect(poll.status, MagicLinkStatus.ready);
          expect(
            await storage.readCookie(),
            '__Secure-better-auth.session_token=sess-secure',
          );
        },
      );

      test('maps expired / consumed / unbound', () async {
        for (final s in ['expired', 'consumed', 'unbound']) {
          final client = MockClient(
            (req) async => http.Response(jsonEncode({'status': s}), 200),
          );
          final poll = await make(
            client,
            _InMemoryStorage(),
          ).pollStatus(session);
          expect(poll.status.name, s);
        }
      });

      test(
        'transient network failure maps to error (caller keeps polling)',
        () async {
          final client = MockClient((req) async => throw Exception('boom'));
          final poll = await make(
            client,
            _InMemoryStorage(),
          ).pollStatus(session);
          expect(poll.status, MagicLinkStatus.error);
        },
      );

      test('ready without a session cookie maps to error', () async {
        final storage = _InMemoryStorage();
        final client = MockClient(
          (req) async => http.Response(jsonEncode({'status': 'ready'}), 200),
        );
        final poll = await make(client, storage).pollStatus(session);
        expect(poll.status, MagicLinkStatus.error);
        expect(await storage.readCookie(), isNull);
      });

      test('200 with a non-JSON body maps to error', () async {
        final client = MockClient(
          (req) async => http.Response('not json', 200),
        );
        final poll = await make(client, _InMemoryStorage()).pollStatus(session);
        expect(poll.status, MagicLinkStatus.error);
      });

      test('pollStatus surfaces delivery=bounced while pending', () async {
        final storage = _InMemoryStorage();
        final client = MockClient((req) async {
          return http.Response(
            '{"status":"pending","delivery":"bounced"}',
            200,
          );
        });
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: client,
        );
        final poll = await service.pollStatus(
          MagicLinkSession(id: 'row-1', bindCookie: 'cookie-1'),
        );
        expect(poll.status, MagicLinkStatus.pending);
        expect(poll.delivery, DeliveryStatus.bounced);
      });

      test('pollStatus reports delivery=null when absent', () async {
        final storage = _InMemoryStorage();
        final client = MockClient((req) async {
          return http.Response('{"status":"pending"}', 200);
        });
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: client,
        );
        final poll = await service.pollStatus(
          MagicLinkSession(id: 'row-1', bindCookie: 'cookie-1'),
        );
        expect(poll.status, MagicLinkStatus.pending);
        expect(poll.delivery, isNull);
      });
    });

    group('session cookie replay', () {
      // Regression: the server reads the session back under the SAME name it
      // set — the `__Secure-`-prefixed name over https (Better-Auth's
      // `useSecureCookies`). The app stores the full `name=value` pair and must
      // replay it verbatim; sending a bare/wrong name makes getSession() find
      // no session → /account/me 401s → the user never appears signed in even
      // though the magic-link poll reached `ready`.
      test(
        'fetchCurrentUser replays the stored pair verbatim (https/prod)',
        () async {
          late http.Request captured;
          final storage = _InMemoryStorage();
          await storage.writeCookie(
            '__Secure-better-auth.session_token=sess-secure',
          );
          final client = MockClient((req) async {
            captured = req;
            return http.Response(
              jsonEncode({'userId': 'u1', 'email': 'a@b.com', 'tier': 'pro'}),
              200,
            );
          });
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: storage,
            httpClient: client,
          );
          final user = await service.fetchCurrentUser();
          expect(user?.userId, 'u1');
          expect(
            captured.headers['cookie'],
            '__Secure-better-auth.session_token=sess-secure',
          );
        },
      );

      test(
        'fetchCurrentUser replays the bare pair verbatim (http loopback dev)',
        () async {
          late http.Request captured;
          final storage = _InMemoryStorage();
          await storage.writeCookie('better-auth.session_token=sess-dev');
          final client = MockClient((req) async {
            captured = req;
            return http.Response(
              jsonEncode({'userId': 'u1', 'email': 'a@b.com'}),
              200,
            );
          });
          final service = AuthService(
            licenseApiUrl: 'http://localhost:8787',
            storage: storage,
            httpClient: client,
          );
          await service.fetchCurrentUser();
          expect(
            captured.headers['cookie'],
            'better-auth.session_token=sess-dev',
          );
        },
      );

      test('signOut replays the stored pair verbatim (https/prod)', () async {
        late http.Request captured;
        final storage = _InMemoryStorage();
        await storage.writeCookie(
          '__Secure-better-auth.session_token=sess-secure',
        );
        final client = MockClient((req) async {
          captured = req;
          return http.Response('', 200);
        });
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: client,
        );
        await service.signOut();
        expect(
          captured.headers['cookie'],
          '__Secure-better-auth.session_token=sess-secure',
        );
      });
    });

    group('transport guard', () {
      test('rejects plaintext http to a non-local host', () async {
        final service = AuthService(
          licenseApiUrl: 'http://evil.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient((req) async => http.Response('{}', 200)),
        );
        expect(
          () => service.startMagicLink('a@b.com'),
          throwsA(isA<AuthException>()),
        );
      });

      test('allows http to localhost (dev)', () async {
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({'id': 'x'}),
            200,
            headers: {'set-cookie': 'antgrid.cross_device_token=x.t; Path=/'},
          ),
        );
        final service = AuthService(
          licenseApiUrl: 'http://localhost:8787',
          storage: _InMemoryStorage(),
          httpClient: client,
        );
        final session = await service.startMagicLink('a@b.com');
        expect(session.id, 'x');
      });

      test('allows http to IPv6 loopback ::1 (dev)', () async {
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({'id': 'x'}),
            200,
            headers: {'set-cookie': 'antgrid.cross_device_token=x.t; Path=/'},
          ),
        );
        final service = AuthService(
          licenseApiUrl: 'http://[::1]:8787',
          storage: _InMemoryStorage(),
          httpClient: client,
        );
        final session = await service.startMagicLink('a@b.com');
        expect(session.id, 'x');
      });

      test(
        'fetchCurrentUser does not send the cookie over insecure transport',
        () async {
          var requested = false;
          final storage = _InMemoryStorage();
          await storage.writeCookie('sess-secret');
          final service = AuthService(
            licenseApiUrl: 'http://evil.test',
            storage: storage,
            httpClient: MockClient((req) async {
              requested = true;
              return http.Response('{}', 200);
            }),
          );
          final user = await service.fetchCurrentUser();
          expect(user, isNull);
          expect(requested, isFalse, reason: 'must not leak token over http');
        },
      );

      test(
        'signOut over insecure transport clears locally without sending',
        () async {
          var requested = false;
          final storage = _InMemoryStorage();
          await storage.writeCookie('sess-secret');
          final service = AuthService(
            licenseApiUrl: 'http://evil.test',
            storage: storage,
            httpClient: MockClient((req) async {
              requested = true;
              return http.Response('', 200);
            }),
          );
          await service.signOut();
          expect(await storage.readCookie(), isNull);
          expect(requested, isFalse, reason: 'must not leak token over http');
        },
      );
    });

    group('password sign-in', () {
      test('stores the session cookie on success', () async {
        final storage = _InMemoryStorage();
        late http.Request captured;
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: MockClient((req) async {
            captured = req;
            return http.Response(
              jsonEncode({'token': 't'}),
              200,
              headers: {
                'set-cookie':
                    '__Secure-better-auth.session_token=signed.abc; Path=/; HttpOnly',
              },
            );
          }),
        );

        final outcome = await service.signInWithPassword(
          email: 'A@B.com',
          password: 'correct horse battery',
        );

        expect(outcome, PasswordSignIn.ok);
        expect(captured.url.path, '/api/auth/sign-in/email');
        expect(
          await storage.readCookie(),
          '__Secure-better-auth.session_token=signed.abc',
          reason: 'the prefixed name is stored verbatim for replay',
        );
      });

      test('normalizes the address but never the password', () async {
        late http.Request captured;
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient((req) async {
            captured = req;
            return http.Response(
              jsonEncode({'code': 'INVALID_EMAIL_OR_PASSWORD'}),
              401,
            );
          }),
        );

        await service.signInWithPassword(
          email: '  Mixed@Case.COM ',
          password: '  spaces matter  ',
        );

        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['email'], 'mixed@case.com');
        expect(
          body['password'],
          '  spaces matter  ',
          reason: 'trimming would break every later compare server-side',
        );
      });

      test('reports EMAIL_NOT_VERIFIED as a state, not a failure', () async {
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient(
            (req) async => http.Response(
              jsonEncode({'code': 'EMAIL_NOT_VERIFIED', 'message': 'nope'}),
              403,
            ),
          ),
        );

        expect(
          await service.signInWithPassword(email: 'a@b.com', password: 'pw'),
          PasswordSignIn.emailNotVerified,
        );
      });

      test('collapses a rejected credential to one outcome', () async {
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient(
            (req) async => http.Response(
              jsonEncode({'code': 'INVALID_EMAIL_OR_PASSWORD'}),
              401,
            ),
          ),
        );

        expect(
          await service.signInWithPassword(email: 'a@b.com', password: 'pw'),
          PasswordSignIn.invalidCredentials,
        );
      });

      test('does not write a cookie the server never sent', () async {
        final storage = _InMemoryStorage();
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: storage,
          httpClient: MockClient((req) async => http.Response('{}', 200)),
        );

        await expectLater(
          service.signInWithPassword(email: 'a@b.com', password: 'pw'),
          throwsA(isA<AuthException>()),
        );
        expect(await storage.readCookie(), isNull);
      });

      test('refuses to send a password over plaintext', () async {
        var requested = false;
        final service = AuthService(
          licenseApiUrl: 'http://evil.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient((req) async {
            requested = true;
            return http.Response('{}', 200);
          }),
        );

        await expectLater(
          service.signInWithPassword(email: 'a@b.com', password: 'pw'),
          throwsA(isA<AuthException>()),
        );
        expect(requested, isFalse);
      });
    });

    group('password sign-up', () {
      test(
        'sends the address as the required name and mints no session',
        () async {
          final storage = _InMemoryStorage();
          late http.Request captured;
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: storage,
            httpClient: MockClient((req) async {
              captured = req;
              return http.Response(jsonEncode({'user': {}}), 200);
            }),
          );

          await service.signUpWithPassword(
            email: 'New@User.com',
            password: 'a-very-long-password',
          );

          expect(captured.url.path, '/api/auth/sign-up/email');
          final body = jsonDecode(captured.body) as Map<String, dynamic>;
          expect(body['email'], 'new@user.com');
          expect(body['name'], 'new@user.com');
          expect(
            await storage.readCookie(),
            isNull,
            reason: 'autoSignIn is off — no session exists until verification',
          );
        },
      );

      test('rejects a short password before the round trip', () async {
        var requested = false;
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient((req) async {
            requested = true;
            return http.Response('{}', 200);
          }),
        );

        await expectLater(
          service.signUpWithPassword(email: 'a@b.com', password: 'short'),
          throwsA(
            isA<AuthException>().having(
              (e) => e.message,
              'message',
              contains('$kMinPasswordLength'),
            ),
          ),
        );
        expect(requested, isFalse);
      });

      test(
        'rejects a password past the ceiling before the round trip',
        () async {
          var requested = false;
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: _InMemoryStorage(),
            httpClient: MockClient((req) async {
              requested = true;
              return http.Response('{}', 200);
            }),
          );

          await expectLater(
            service.signUpWithPassword(
              email: 'a@b.com',
              password: 'x' * (kMaxPasswordLength + 1),
            ),
            throwsA(isA<AuthException>()),
          );
          expect(
            requested,
            isFalse,
            reason: 'the server throws PASSWORD_TOO_LONG with no branch here',
          );
        },
      );
    });

    group('verification and reset sends', () {
      test(
        'sends no cookie, so the endpoint takes its anonymous branch',
        () async {
          final storage = _InMemoryStorage();
          await storage.writeCookie('better-auth.session_token=live.session');
          late http.Request captured;
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: storage,
            httpClient: MockClient((req) async {
              captured = req;
              return http.Response(jsonEncode({'status': true}), 200);
            }),
          );

          await service.sendVerificationEmail('a@b.com');

          expect(captured.url.path, '/api/auth/send-verification-email');
          expect(
            captured.headers.keys.map((k) => k.toLowerCase()),
            isNot(contains('cookie')),
            reason: 'a session turns this into EMAIL_MISMATCH/ALREADY_VERIFIED',
          );
        },
      );

      test('reset carries no redirectTo for originCheck to reject', () async {
        late http.Request captured;
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient((req) async {
            captured = req;
            return http.Response(jsonEncode({'status': true}), 200);
          }),
        );

        await service.requestPasswordReset('  A@B.com ');

        expect(captured.url.path, '/api/auth/request-password-reset');
        final body = jsonDecode(captured.body) as Map<String, dynamic>;
        expect(body['email'], 'a@b.com');
        expect(body.containsKey('redirectTo'), isFalse);
      });

      test(
        'swallows a non-2xx — the answer is uniform and tells us nothing',
        () async {
          final service = AuthService(
            licenseApiUrl: 'https://lic.test',
            storage: _InMemoryStorage(),
            httpClient: MockClient(
              (req) async =>
                  http.Response(jsonEncode({'code': 'USER_NOT_FOUND'}), 400),
            ),
          );

          await expectLater(
            service.sendVerificationEmail('a@b.com'),
            completes,
          );
          await expectLater(service.requestPasswordReset('a@b.com'), completes);
        },
      );

      test('reports a network failure — nothing was sent', () async {
        final service = AuthService(
          licenseApiUrl: 'https://lic.test',
          storage: _InMemoryStorage(),
          httpClient: MockClient((req) async => throw Exception('offline')),
        );

        // The distinction the swallow above must not eat: the request never
        // reached the server, so saying so leaks nothing about the address —
        // and claiming success strands the user waiting on mail nobody sent.
        await expectLater(
          service.sendVerificationEmail('a@b.com'),
          throwsA(isA<AuthException>()),
        );
        await expectLater(
          service.requestPasswordReset('a@b.com'),
          throwsA(isA<AuthException>()),
        );
      });
    });
  });
}
