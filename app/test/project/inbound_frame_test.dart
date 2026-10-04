import 'dart:async';

import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/project/inbound_frame.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';

Map<String, dynamic> _statusFrame(String id) => {
  'id': id,
  'timestamp': 0,
  'type': 'agent:status',
  'projectId': 'p',
  'terminals': <Object>[],
  'services': [
    {'id': 'svc-1', 'name': 'dev', 'running': true, 'command': 'npm run dev'},
  ],
  'commands': <Object>[],
  'proxies': <Object>[],
  'ports': <Object>[],
};

void main() {
  group('InboundFrame', () {
    test('a subscriber that never reads parsed never triggers the parser', () {
      var calls = 0;
      final frame = InboundFrame(
        {'type': 'agent:status'},
        parser: (_) {
          calls++;
          return null;
        },
      );
      expect(frame.type, 'agent:status');
      expect(frame.checkoutId, 'main');
      expect(calls, 0);
    });

    test('a throwing parser runs once and reads as null every time', () {
      var calls = 0;
      final frame = InboundFrame(
        {'type': 'agent:status'},
        parser: (_) {
          calls++;
          throw const FormatException('bad');
        },
      );
      expect(frame.parsed, isNull);
      expect(frame.parsed, isNull);
      expect(calls, 1);
    });

    test('a successful parse is memoised', () {
      var calls = 0;
      final frame = InboundFrame(
        {'type': 'x'},
        parser: (_) {
          calls++;
          return Object();
        },
      );
      expect(identical(frame.parsed, frame.parsed), isTrue);
      expect(calls, 1);
    });
  });

  group('router parse seam', () {
    late FakeAgentTransport transport;
    late ProjectSession session;
    late Map<Map<String, dynamic>, int> calls;
    late Map<Object?, int> callsById;

    setUp(() async {
      transport = FakeAgentTransport();
      calls = Map.identity();
      callsById = {};
      final cache = await CachedSessionsStore.open();
      session = ProjectSession(
        projectId: 'p',
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
        frameParser: (json) {
          calls[json] = (calls[json] ?? 0) + 1;
          callsById[json['id']] = (callsById[json['id']] ?? 0) + 1;
          return parseAbMessage(json);
        },
      );
    });

    tearDown(() => session.close());

    test(
      'a malformed frame is swallowed once and the next valid frame applies',
      () async {
        final errors = <Object>[];
        await runZonedGuarded(() async {
          final bad = {
            'id': '7',
            'timestamp': 0,
            'type': 'agent:status',
            'terminals': 7,
          };
          transport.emitJson(bad);
          await Future<void>.delayed(Duration.zero);
          transport.emitJson(_statusFrame('1'));
          await Future<void>.delayed(Duration.zero);

          expect(calls[bad], 1);
        }, (e, _) => errors.add(e));

        expect(errors, isEmpty);
        expect(session.status.value.services, isNotEmpty);
      },
    );

    test('each envelope is parsed at most once across every consumer', () async {
      final frames = [
        _statusFrame('1'),
        {
          'id': '2',
          'timestamp': 0,
          'type': 'tree:update',
          'projectId': 'p',
          'added': [],
          'modified': [],
          'removed': [],
        },
        {'id': '3', 'timestamp': 0, 'type': 'session:updated'},
        {'id': '4', 'timestamp': 0, 'type': 'git:status', 'files': []},
        {
          'id': '5',
          'timestamp': 0,
          'type': 'agent:item-added',
          'sessionId': 's',
          'turnId': 't',
          'item': {'itemId': 'i', 'kind': 'message', 'role': 'assistant'},
        },
        {'id': '6', 'timestamp': 0, 'type': 'handler:activity'},
        {'id': '7', 'timestamp': 0, 'type': 'terminal:frame'},
      ];
      for (final f in frames) {
        transport.emitJson(f);
      }
      await Future<void>.delayed(Duration.zero);

      // A late subscriber is seeded from the durable replay with the very
      // frame object the live consumers already parsed.
      final sub = session.checkoutStatusStream('main').listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      // Counted by envelope id, not map identity: a consumer parsing its own
      // copy of a frame must count against the same envelope.
      expect(callsById, isNotEmpty, reason: 'nothing was parsed at all');
      for (final MapEntry(key: id, value: n) in callsById.entries) {
        expect(n, 1, reason: 'envelope $id');
      }
    });
  });
}
