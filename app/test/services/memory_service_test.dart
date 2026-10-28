import 'dart:async';

import 'package:antgrid/models/memory.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/memory_service.dart';
import 'package:antgrid/services/pending_reply.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid_relay_client/antgrid_relay_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<ProjectSession> sessionFor(FakeAgentTransport transport) async =>
      ProjectSession(
        projectId: 'project-allowed',
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: await CachedSessionsStore.open(),
        onClose: transport.dispose,
      );

  test(
    'requests stay on the admitted project and correlate concurrent responses',
    () async {
      final transport = FakeAgentTransport();
      final session = await sessionFor(transport);
      addTearDown(session.close);
      final first = requestProjectMemory(session, {'op': 'status'});
      final second = requestProjectMemory(session, {
        'op': 'list',
        'history': true,
      });
      await Future<void>.delayed(Duration.zero);
      final messages = transport.sent
          .where((message) => message['type'] == 'memory:request')
          .toList();
      expect(messages, hasLength(2));
      expect(messages[0].containsKey('projectId'), isFalse);
      expect(messages[0].containsKey('checkoutId'), isFalse);
      transport.emit('memory:result', {
        'requestId': messages[1]['requestId'],
        'ok': true,
        'result': {'results': [], 'has_more': false},
      });
      transport.emit('memory:result', {
        'requestId': messages[0]['requestId'],
        'ok': true,
        'result': {'enabled': false},
      });
      expect(await first, {'enabled': false});
      expect(await second, {'results': [], 'has_more': false});
    },
  );

  test('typed refusals do not become empty memory results', () async {
    final transport = FakeAgentTransport();
    final session = await sessionFor(transport);
    addTearDown(session.close);
    final result = requestProjectMemory(session, {'op': 'get', 'id': 'other'});
    final expected = expectLater(
      result,
      throwsA(
        isA<MemoryException>().having(
          (error) => error.code,
          'code',
          'NOT_FOUND',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final message = transport.sent.lastWhere(
      (message) => message['type'] == 'memory:request',
    );
    transport.emit('memory:result', {
      'requestId': message['requestId'],
      'ok': false,
      'error': {'code': 'NOT_FOUND', 'message': 'Record unavailable'},
    });
    await expected;
  });

  test(
    'lost replies time out and a closed connection fails pending inspection',
    () async {
      final transport = FakeAgentTransport();
      final session = await sessionFor(transport);
      addTearDown(session.close);
      await expectLater(
        requestProjectMemory(session, {
          'op': 'status',
        }, timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
      final pending = requestProjectMemory(session, {'op': 'status'});
      final expected = expectLater(
        pending,
        throwsA(isA<SessionDownException>()),
      );
      transport.emitState(TransportState.disconnected);
      await expected;
    },
  );
}
