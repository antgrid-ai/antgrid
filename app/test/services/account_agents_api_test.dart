import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:antgrid/services/account_agents_api.dart';

void main() {
  group('AccountAgentsApi', () {
    const baseUrl = 'https://lic.test';
    // The provider yields the full session cookie `name=value` pair (prefixed
    // over https); the client must replay it verbatim.
    const sessionCookie = '__Secure-better-auth.session_token=my-session-token';

    http.Request? capturedRequest;

    MockClient makeMockClient(Map<String, dynamic> body, {int status = 200}) {
      return MockClient((request) async {
        capturedRequest = request;
        return http.Response(jsonEncode(body), status);
      });
    }

    setUp(() {
      capturedRequest = null;
    });

    test('listAgents hits /account/agents', () async {
      final client = makeMockClient({
        'agents': [
          {
            'deviceUuid': 'uuid-1',
            'displayName': 'My MacBook',
            'platform': 'macos',
            'ed25519Pub': 'base64pubkey==',
            'relayUrl': 'wss://relay.example.com',
            'lastSeenAt': '2026-05-28T10:00:00.000Z',
          },
        ],
      });

      final api = AccountAgentsApi(
        baseUrl: baseUrl,
        sessionCookieProvider: () async => sessionCookie,
        httpClient: client,
      );

      await api.listAgents();

      expect(capturedRequest, isNotNull);
      expect(capturedRequest!.url.toString(), contains('/account/agents'));
    });

    test('listAgents sends correct session cookie header', () async {
      final client = makeMockClient({'agents': []});
      final api = AccountAgentsApi(
        baseUrl: baseUrl,
        sessionCookieProvider: () async => sessionCookie,
        httpClient: client,
      );

      await api.listAgents();

      expect(capturedRequest!.headers['cookie'], equals(sessionCookie));
    });

    test('listAgents parses InventoryAgent list correctly', () async {
      final lastSeen = '2026-05-28T10:00:00.000Z';
      final client = makeMockClient({
        'agents': [
          {
            'deviceUuid': 'uuid-1',
            'displayName': 'My MacBook',
            'platform': 'macos',
            'ed25519Pub': 'base64pubkey==',
            'relayUrl': 'wss://relay.example.com',
            'lastSeenAt': lastSeen,
          },
          {
            'deviceUuid': 'uuid-2',
            'displayName': 'Linux Box',
            'platform': 'linux',
            'ed25519Pub': 'anotherkey==',
            'relayUrl': null,
            'lastSeenAt': null,
          },
        ],
      });

      final api = AccountAgentsApi(
        baseUrl: baseUrl,
        sessionCookieProvider: () async => sessionCookie,
        httpClient: client,
      );

      final agents = await api.listAgents();

      expect(agents.length, 2);

      final first = agents[0];
      expect(first.deviceUuid, 'uuid-1');
      expect(first.displayName, 'My MacBook');
      expect(first.platform, 'macos');
      expect(first.ed25519Pub, 'base64pubkey==');
      expect(first.relayUrl, 'wss://relay.example.com');
      expect(first.lastSeenAt, DateTime.parse(lastSeen));

      final second = agents[1];
      expect(second.deviceUuid, 'uuid-2');
      expect(second.relayUrl, isNull);
      expect(second.lastSeenAt, isNull);
    });

    test('listAgents throws on 401', () async {
      final client = MockClient(
        (_) async => http.Response('{"error":"Not signed in"}', 401),
      );
      final api = AccountAgentsApi(
        baseUrl: baseUrl,
        sessionCookieProvider: () async => sessionCookie,
        httpClient: client,
      );

      await expectLater(
        api.listAgents(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Not signed in'),
          ),
        ),
      );
    });

    test('listAgents throws on non-200 non-401', () async {
      final client = MockClient(
        (_) async => http.Response('Internal Server Error', 500),
      );
      final api = AccountAgentsApi(
        baseUrl: baseUrl,
        sessionCookieProvider: () async => sessionCookie,
        httpClient: client,
      );

      await expectLater(
        api.listAgents(),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('500'),
          ),
        ),
      );
    });
  });
}
