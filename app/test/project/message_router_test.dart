import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/message_router.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';

void main() {
  late FakeAgentTransport transport;
  late MessageRouter router;

  setUp(() {
    transport = FakeAgentTransport();
    router = MessageRouter(transport: transport);
  });

  tearDown(() async {
    await router.dispose();
    await transport.dispose();
  });

  test('routes status-tier messages to status stream', () async {
    final received = <Map<String, dynamic>>[];
    final sub = router.status.listen(received.add);

    transport.emit('agent:status', {'status': 'ready'});
    transport.emit('session:updated', {'sessionId': 's1'});
    transport.emit('terminal:output', {'data': 'hello'});

    await Future<void>.delayed(Duration.zero);

    expect(received.map((m) => m['type']).toList(), [
      'agent:status',
      'session:updated',
    ]);

    await sub.cancel();
  });

  test(
    'routes heavy-tier only when subscribed; sends focus-state on attach/detach',
    () async {
      expect(transport.sent, isEmpty);

      final received = <Map<String, dynamic>>[];
      final sub = router.heavy.listen(received.add);
      await Future<void>.delayed(Duration.zero);

      expect(transport.sent.length, 1);
      expect(transport.sent.first['type'], 'client:focus-state');
      expect(transport.sent.first['paused'], false);

      transport.emit('terminal:output', {'data': 'chunk'});
      await Future<void>.delayed(Duration.zero);
      expect(received.length, 1);
      expect(received.first['type'], 'terminal:output');

      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      expect(transport.sent.length, 2);
      expect(transport.sent.last['type'], 'client:focus-state');
      expect(transport.sent.last['paused'], true);
    },
  );

  test('ignore-tier messages do not reach either stream', () async {
    final statusRx = <Map<String, dynamic>>[];
    final heavyRx = <Map<String, dynamic>>[];
    final s1 = router.status.listen(statusRx.add);
    final s2 = router.heavy.listen(heavyRx.add);

    transport.emit('ping');
    transport.emit('handshake:agent-ready');

    await Future<void>.delayed(Duration.zero);

    expect(statusRx, isEmpty);
    expect(heavyRx, isEmpty);

    await s1.cancel();
    await s2.cancel();
  });
}
