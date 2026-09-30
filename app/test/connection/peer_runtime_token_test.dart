import 'dart:convert';

import 'package:antgrid/connection/peer_runtime.dart';
import 'package:antgrid/services/license_token_minter.dart';
import 'package:antgrid_peer_transport/antgrid_peer_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../helpers/test_peer_runtime.dart';

/// One fake web answering both the token endpoint and the authorization
/// routes, behind a runtime that borrows a real minter's cache.
class _Web {
  var minted = 0;
  final presented = <String>[];
  final refused = <String>{};
  var refusal = 401;
  var rateLimited = false;
  var now = DateTime.utc(2026);

  late final _client = MockClient((request) async {
    if (request.url.path == '/api/auth/oauth2/token') {
      minted++;
      if (rateLimited) return http.Response('', 429);
      return http.Response(
        jsonEncode({'access_token': 'tok-$minted', 'expires_in': 3600}),
        200,
      );
    }
    final token = request.headers['authorization']!.split(' ').last;
    presented.add(token);
    if (refused.contains(token)) return http.Response('', refusal);
    return http.Response(leaseSnapshotJson, 200);
  });
  late final minter = LicenseTokenMinter(
    licenseApiUrl: 'https://api.test',
    clientId: 'credential',
    clientSecret: 'secret',
    httpClient: _client,
    now: () => now,
  );
  late final runtime = PeerRuntime(
    record: leaseRecord(),
    licenseApiUrl: 'https://api.test',
    mintToken: minter.token,
    rejectToken: minter.discard,
    httpClient: _client,
  );
}

void main() {
  late _Web web;
  late AuthorizationLease lease;
  setUp(() {
    web = _Web();
    lease = web.runtime.lease;
    addTearDown(web.runtime.dispose);
  });

  test('a refused reused token is discarded and retried fresh', () async {
    expect(await lease.refresh(), isTrue);
    web.refused.add('tok-1');
    expect(await lease.refresh(), isTrue);
    expect(web.presented, ['tok-1', 'tok-1', 'tok-2']);
    expect(lease.permits(leasePeerId), isTrue);
  });

  test('a refused fresh token is a denial without another mint', () async {
    web.refused.add('tok-1');
    expect(await lease.refresh(), isFalse);
    expect(lease.lastRefreshFailure, isA<PeerAuthorizationDenied>());
    expect(web.presented, ['tok-1']);
    expect(web.minted, 1);
  });

  test('a refusal of the fresh retry is a denial', () async {
    expect(await lease.refresh(), isTrue);
    web.refused.addAll(['tok-1', 'tok-2']);
    expect(await lease.refresh(), isFalse);
    expect(lease.lastRefreshFailure, isA<PeerAuthorizationDenied>());
    expect(web.presented, ['tok-1', 'tok-1', 'tok-2']);
  });

  test('a 403 is a denial that keeps the cached token', () async {
    expect(await lease.refresh(), isTrue);
    web.refused.add('tok-1');
    web.refusal = 403;
    expect(await lease.refresh(), isFalse);
    expect(lease.lastRefreshFailure, isA<PeerAuthorizationDenied>());
    expect(web.presented, ['tok-1', 'tok-1']);
    expect(web.minter.getToken(), 'tok-1');
  });

  test(
    'lease refreshes survive rate-limited renewal without more mints',
    () async {
      expect(await lease.refresh(), isTrue);
      web.rateLimited = true;
      web.now = web.now.add(const Duration(seconds: 2880));
      expect(await lease.refresh(), isTrue);
      for (var i = 0; i < 3; i++) {
        web.now = web.now.add(const Duration(seconds: 20));
        expect(await lease.refresh(), isTrue);
        expect(lease.permits(leasePeerId), isTrue);
        expect(web.minted, 2);
      }
      web.rateLimited = false;
      web.now = web.now.add(const Duration(seconds: 5));
      expect(await lease.refresh(), isTrue);
      expect(web.minted, 3);
      expect(web.presented.last, 'tok-3');
    },
  );
}
