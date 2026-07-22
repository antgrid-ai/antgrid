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
    final api = _api(MockClient((req) async {
      seen = req;
      return http.Response('{"ok":true}', 200);
    }));
    expect(await api.deleteAccount(), DeleteAccountResult.ok);
    expect(seen.method, 'DELETE');
    expect(seen.url.toString(), 'https://api.test/account/me');
    expect(seen.headers['cookie'], 'better-auth.session_token=abc');
  });

  test('409 → blockedBySubscription', () async {
    final api = _api(MockClient((_) async => http.Response('{"error":"SUBSCRIPTION_ACTIVE"}', 409)));
    expect(await api.deleteAccount(), DeleteAccountResult.blockedBySubscription);
  });

  test('500 → error', () async {
    final api = _api(MockClient((_) async => http.Response('nope', 500)));
    expect(await api.deleteAccount(), DeleteAccountResult.error);
  });

  test('no cookie → error (no request made)', () async {
    var called = false;
    final api = AccountApi(
      licenseApiUrl: 'https://api.test',
      cookieProvider: () async => null,
      httpClient: MockClient((_) async { called = true; return http.Response('', 200); }),
    );
    expect(await api.deleteAccount(), DeleteAccountResult.error);
    expect(called, false);
  });
}
