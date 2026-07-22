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

  test(
    'backgrounding pauses focus even while heavy stays subscribed',
    () async {
      final sub = router.heavy.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(transport.sent.last['paused'], false);

      router.setLifecyclePaused(true);
      await Future<void>.delayed(Duration.zero);

      expect(transport.sent.last['type'], 'client:focus-state');
      expect(transport.sent.last['paused'], true);

      await sub.cancel();
    },
  );

  test('heavy re-subscribe while backgrounded does not unpause', () async {
    final first = router.heavy.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    router.setLifecyclePaused(true);
    await Future<void>.delayed(Duration.zero);
    final sentAfterPause = transport.sent.length;

    await first.cancel();
    final second = router.heavy.listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(transport.sent.length, sentAfterPause);
    expect(transport.sent.last['paused'], true);

    await second.cancel();
  });

  test('resuming unpauses once the app returns to the foreground', () async {
    final sub = router.heavy.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    router.setLifecyclePaused(true);
    await Future<void>.delayed(Duration.zero);

    router.setLifecyclePaused(false);
    await Future<void>.delayed(Duration.zero);

    expect(transport.sent.last['paused'], false);

    await sub.cancel();
  });

  test('resyncFocusState re-asserts the union after a handshake', () async {
    // Regression: `transport.send` is a silent no-op until session keys are
    // installed, but _syncFocusState records the value as sent regardless. A
    // phone backgrounding across a reconnect (the common case — the OS suspends
    // the socket exactly then) loses `{paused: true}` and the dedup blocks every
    // retry, so the agent keeps believing the app is foregrounded and skips the
    // fallback push forever. The post-handshake resync must re-send the union
    // even though the value hasn't changed.
    final sub = router.heavy.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    router.setLifecyclePaused(true);
    await Future<void>.delayed(Duration.zero);
    transport.sent.clear(); // pretend everything so far was dropped pre-handshake

    router.resyncFocusState();
    await Future<void>.delayed(Duration.zero);

    expect(transport.sent.length, 1);
    expect(transport.sent.single['type'], 'client:focus-state');
    expect(transport.sent.single['paused'], true);

    await sub.cancel();
  });

  test('resyncFocusState is a no-op before any focus state is established', () async {
    // Nothing has been declared yet (no heavy subscriber, no lifecycle call), so
    // a handshake must not invent a focus claim the app never made.
    router.resyncFocusState();
    await Future<void>.delayed(Duration.zero);

    expect(transport.sent, isEmpty);
  });

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
