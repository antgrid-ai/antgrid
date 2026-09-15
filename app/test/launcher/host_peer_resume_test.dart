import 'dart:async';

import 'package:antgrid/launcher/host_control_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'resume uses owner token and an empty body on the dedicated route',
    () async {
      final client = HostControlClient(
        port: 54321,
        token: 'owner-secret',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.toString(), 'http://127.0.0.1:54321/peer-resume');
          expect(request.headers['authorization'], 'Bearer owner-secret');
          expect(request.body, isEmpty);
          return http.Response('{"ok":true}', 202);
        }),
      );
      addTearDown(client.close);
      await client.peerResume();
    },
  );

  for (final status in [200, 401, 500]) {
    test('resume requires the host fence acknowledgement ($status)', () async {
      final client = HostControlClient(
        port: 54321,
        token: 'owner-secret',
        httpClient: MockClient(
          (_) async => http.Response('{"ok":true}', status),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        client.peerResume(),
        throwsA(isA<HostControlException>()),
      );
    });
  }

  test('unresponsive host notification is bounded', () async {
    final response = Completer<http.Response>();
    final client = HostControlClient(
      port: 54321,
      token: 'owner-secret',
      httpClient: MockClient((_) => response.future),
    );
    addTearDown(client.close);
    await expectLater(
      client.peerResume(timeout: const Duration(milliseconds: 1)),
      throwsA(
        isA<HostControlException>().having((e) => e.code, 'code', 'TRANSPORT'),
      ),
    );
    response.complete(http.Response('{"ok":true}', 202));
  });
}
