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
          'allowedProjects': ['p1'], 'admission': 'same-account',
        }],
        'knownProjects': [{'projectId': 'p1', 'label': 'Proj', 'path': '/x', 'running': true}],
      }), 200);
    });
    final c = HostControlClient(port: 1, token: 't', httpClient: mock);
    final res = await c.phonesList();
    expect(res.phones.single.phonePubkey, 'pk-1');
    expect(res.phones.single.allowedProjects, ['p1']);
    expect(res.knownProjects.single.projectId, 'p1');
    expect(res.knownProjects.single.running, true);
  });

  test('phonesAllow posts the expected verb', () async {
    var seen = <String, dynamic>{};
    final mock = MockClient((req) async {
      seen = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(jsonEncode({'id': seen['id'], 'ok': true, 'type': 'phones:allow'}), 200);
    });
    final c = HostControlClient(port: 1, token: 't', httpClient: mock);
    await c.phonesAllow(phonePubkey: 'pk-1', projectId: 'p2');
    expect(seen['type'], 'phones:allow');
    expect(seen['phonePubkey'], 'pk-1');
    expect(seen['projectId'], 'p2');
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
          'allowedProjects': <String>[],
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

  test('mobileAccessGet parses project ids', () async {
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
          'projectIds': ['p1'],
        }), 200);
      }),
    );

    final policy = await client.mobileAccessGet();
    expect(policy.projectIds, ['p1']);
  });

  test('mobileAccessEnableProject sends project id and parses returned policy', () async {
    final client = HostControlClient(
      port: 1,
      token: 't',
      httpClient: MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        expect(body['type'], 'mobile-access:enable-project');
        expect(body['projectId'], 'p2');
        return http.Response(jsonEncode({
          'id': body['id'],
          'ok': true,
          'type': 'mobile-access:enable-project',
          'projectIds': ['p2'],
        }), 200);
      }),
    );

    final policy = await client.mobileAccessEnableProject('p2');
    expect(policy.projectIds, ['p2']);
  });
}
