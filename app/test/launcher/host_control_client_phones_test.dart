import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:antgrid/launcher/host_control_client.dart';

void main() {
  test('phonesList parses phones + knownProjects', () async {
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['type'], 'phones:list');
      return http.Response(jsonEncode({
        'id': body['id'], 'ok': true, 'type': 'phones:list',
        'phones': [{
          'phonePubkey': 'pk-1', 'phoneDeviceId': 'ph-1', 'label': 'iPhone',
          'pairedAt': '2026-01-01T00:00:00.000Z', 'lastSeenAt': '2026-01-02T00:00:00.000Z',
        }],
        'knownProjects': [{'projectId': 'p1', 'label': 'Proj', 'path': '/x', 'running': true}],
      }), 200);
    });
    final c = HostControlClient(port: 1, token: 't', httpClient: mock);
    final res = await c.phonesList();
    expect(res.phones.single.phonePubkey, 'pk-1');
    expect(res.phones.single.label, 'iPhone');
    expect(res.knownProjects.single.projectId, 'p1');
    expect(res.knownProjects.single.running, true);
  });

  test('phonesUnpair posts the expected verb', () async {
    var seen = <String, dynamic>{};
    final mock = MockClient((req) async {
      seen = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'id': seen['id'], 'ok': true, 'type': 'phones:unpair'}), 200);
    });
    final c = HostControlClient(port: 1, token: 't', httpClient: mock);
    await c.phonesUnpair(phonePubkey: 'pk-1');
    expect(seen['type'], 'phones:unpair');
    expect(seen['phonePubkey'], 'pk-1');
  });

  test('phonesList throws HostControlException on a malformed phone entry', () async {
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({
        'id': body['id'], 'ok': true, 'type': 'phones:list',
        // phonePubkey missing → guard must reject, not raw _CastError.
        'phones': [{
          'phoneDeviceId': 'ph-1',
          'pairedAt': '2026-01-01T00:00:00.000Z', 'lastSeenAt': '2026-01-02T00:00:00.000Z',
        }],
        'knownProjects': <Map<String, dynamic>>[],
      }), 200);
    });
    final c = HostControlClient(port: 1, token: 't', httpClient: mock);
    expect(
      () => c.phonesList(),
      throwsA(isA<HostControlException>().having((e) => e.code, 'code', 'BAD_RESPONSE')),
    );
  });

  test('phonesList tolerates keys an older bridge still sends', () async {
    final mock = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({
        'id': body['id'], 'ok': true, 'type': 'phones:list',
        'phones': [{
          'phonePubkey': 'pk-1', 'phoneDeviceId': 'ph-1', 'label': 'iPhone',
          'pairedAt': '2026-01-01T00:00:00.000Z', 'lastSeenAt': '2026-01-02T00:00:00.000Z',
          // Both died with the per-phone allowlist; a pre-upgrade bridge still
          // emits them and must not break the parse.
          'allowedProjects': ['p1'],
          'admission': 'same-account',
        }],
        'knownProjects': <Map<String, dynamic>>[],
      }), 200);
    });
    final c = HostControlClient(port: 1, token: 't', httpClient: mock);
    final res = await c.phonesList();
    expect(res.phones.single.phonePubkey, 'pk-1');
  });

  test('mobileAccessGet parses the machine-wide boolean', () async {
    final client = HostControlClient(
      port: 1,
      token: 't',
      httpClient: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['type'], 'mobile-access:get');
        return http.Response(jsonEncode({
          'id': body['id'],
          'ok': true,
          'type': 'mobile-access:get',
          'enabled': true,
        }), 200);
      }),
    );

    final policy = await client.mobileAccessGet();
    expect(policy.enabled, isTrue);
  });

  test('mobileAccessSet sends the requested value and parses what landed', () async {
    var seen = <String, dynamic>{};
    final client = HostControlClient(
      port: 1,
      token: 't',
      httpClient: MockClient((req) async {
        seen = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({
          'id': seen['id'],
          'ok': true,
          'type': 'mobile-access:set',
          'enabled': seen['enabled'],
        }), 200);
      }),
    );

    final on = await client.mobileAccessSet(true);
    expect(seen['type'], 'mobile-access:set');
    expect(seen['enabled'], true);
    expect(on.enabled, isTrue);

    final off = await client.mobileAccessSet(false);
    expect(seen['enabled'], false);
    expect(off.enabled, isFalse);
  });

  test('a response without `enabled` parses as disabled, never as enabled', () async {
    // Fail closed: an old bridge answering `mobile-access:get` with the v1
    // {projectIds} shape must not read as "mobile access is on".
    final client = HostControlClient(
      port: 1,
      token: 't',
      httpClient: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({
          'id': body['id'],
          'ok': true,
          'type': 'mobile-access:get',
          'projectIds': ['p1'],
        }), 200);
      }),
    );

    expect((await client.mobileAccessGet()).enabled, isFalse);
  });
}
