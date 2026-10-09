import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/services/account_api.dart';

AccountApi _api(MockClient client) => AccountApi(
  licenseApiUrl: 'https://api.test',
  cookieProvider: () async => 'better-auth.session_token=abc',
  httpClient: client,
);

void main() {
  test('200 → ok and DELETEs /account/me with the cookie', () async {
    late http.Request seen;
    final api = _api(
      MockClient((req) async {
        seen = req;
        return http.Response('{"ok":true}', 200);
      }),
    );
    expect((await api.deleteAccount()).result, DeleteAccountResult.ok);
    expect(seen.method, 'DELETE');
    expect(seen.url.toString(), 'https://api.test/account/me');
    expect(seen.headers['cookie'], 'better-auth.session_token=abc');
  });

  test('409 SUBSCRIPTION_ACTIVE → blockedBySubscription', () async {
    final api = _api(
      MockClient(
        (_) async => http.Response('{"error":"SUBSCRIPTION_ACTIVE"}', 409),
      ),
    );
    expect(
      (await api.deleteAccount()).result,
      DeleteAccountResult.blockedBySubscription,
    );
  });

  test('409 TEAM_HAS_MEMBERS → blockedByTeam, carrying the server message', () async {
    final api = _api(
      MockClient(
        (_) async => http.Response(
          '{"error":"TEAM_HAS_MEMBERS","message":"Remove them first."}',
          409,
        ),
      ),
    );
    final reply = await api.deleteAccount();
    expect(reply.result, DeleteAccountResult.blockedByTeam);
    expect(reply.message, 'Remove them first.');
  });

  test('409 from a server that sends no message leaves the wording to the app', () async {
    final api = _api(
      MockClient(
        (_) async => http.Response('{"error":"TEAM_HAS_MEMBERS"}', 409),
      ),
    );
    final reply = await api.deleteAccount();
    expect(reply.result, DeleteAccountResult.blockedByTeam);
    expect(reply.message, isNull);
  });

  test('409 with an unknown or unreadable body → blocked', () async {
    for (final body in ['{"error":"SOMETHING_NEW"}', 'conflict', '']) {
      final api = _api(MockClient((_) async => http.Response(body, 409)));
      expect(
        (await api.deleteAccount()).result,
        DeleteAccountResult.blocked,
        reason: body,
      );
    }
  });

  test('500 → error', () async {
    final api = _api(MockClient((_) async => http.Response('nope', 500)));
    expect((await api.deleteAccount()).result, DeleteAccountResult.error);
  });

  test('no cookie → error (no request made)', () async {
    var called = false;
    final api = AccountApi(
      licenseApiUrl: 'https://api.test',
      cookieProvider: () async => null,
      httpClient: MockClient((_) async {
        called = true;
        return http.Response('', 200);
      }),
    );
    expect((await api.deleteAccount()).result, DeleteAccountResult.error);
    expect(called, false);
  });
}
