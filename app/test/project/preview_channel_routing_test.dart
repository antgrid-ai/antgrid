// Proves the negatives the Wave 6 scout only asserted: a preview-channel
// terminal frame reaches its checkout's slice of the heavy tier, and a
// preview-channel tunnel frame — the browser tunnel's own hot path on the
// same wire channel — never does, driven through a real MessageRouter (via
// ProjectSession) over a fake AgentTransport rather than trusted by inspection.
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _openSession(FakeAgentTransport transport) async {
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'p1',
    transport: transport,
    mode: ProjectSessionMode.relay,
    cachedSessionsStore: cache,
    onClose: () async => transport.dispose(),
  );
}

void main() {
  setUp(() {
    useInMemoryPrefs();
  });

  test(
    'a preview-channel terminal:frame reaches its own checkout\'s heavy stream',
    () async {
      final transport = FakeAgentTransport();
      final session = await _openSession(transport);

      final received = <Map<String, dynamic>>[];
      final sub = session.checkoutHeavyStream('checkout-a').listen(received.add);
      await Future<void>.delayed(Duration.zero);

      transport.emitJson({
        'id': '00000000-0000-0000-0000-000000000001',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'terminal:frame',
        'checkoutId': 'checkout-a',
        'terminalId': 'term1',
      }, channel: 'preview');
      await Future<void>.delayed(Duration.zero);

      expect(received.map((m) => m['type']), ['terminal:frame']);

      await sub.cancel();
      await session.close();
    },
  );

  test(
    'a preview-channel terminal:history:page reaches its checkout heavy stream',
    () async {
      final transport = FakeAgentTransport();
      final session = await _openSession(transport);

      final received = <Map<String, dynamic>>[];
      final sub = session.checkoutHeavyStream('checkout-a').listen(received.add);
      await Future<void>.delayed(Duration.zero);

      transport.emitJson({
        'id': '00000000-0000-0000-0000-000000000003',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'terminal:history:page',
        'checkoutId': 'checkout-a',
        'terminalId': 'term1',
      }, channel: 'preview');
      await Future<void>.delayed(Duration.zero);

      expect(received.map((m) => m['type']), ['terminal:history:page']);

      await sub.cancel();
      await session.close();
    },
  );

  test(
    'a preview-channel frame the set does not name is dropped even though its '
    'type routes on control',
    () async {
      final transport = FakeAgentTransport();
      final session = await _openSession(transport);

      final heavy = <Map<String, dynamic>>[];
      final status = <Map<String, dynamic>>[];
      final heavySub =
          session.checkoutHeavyStream('checkout-a').listen(heavy.add);
      final statusSub =
          session.checkoutStatusStream('checkout-a').listen(status.add);
      await Future<void>.delayed(Duration.zero);

      // `tree:update` is chosen over a tunnel type deliberately: a tunnel frame
      // classifies as MessageTier.ignore, so the classifier alone would drop it
      // on every channel and a test using one passes with the channel gate
      // deleted. This type IS heavy, so the only thing that can drop it is the
      // gate — which is what widening the gate to admit the tunnel's
      // full-bandwidth hot path would undo.
      Map<String, dynamic> treeUpdate(String id) => {
            'id': id,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
            'type': 'tree:update',
            'checkoutId': 'checkout-a',
            'changes': <Map<String, dynamic>>[],
          };

      transport.emitJson(treeUpdate('00000000-0000-0000-0000-000000000004'),
          channel: 'preview');
      await Future<void>.delayed(Duration.zero);
      expect(heavy, isEmpty);
      expect(status, isEmpty);

      // Positive control: the same envelope on `control` does reach heavy, so
      // the drop above is the channel gate and not a malformed payload.
      transport.emitJson(treeUpdate('00000000-0000-0000-0000-000000000005'));
      await Future<void>.delayed(Duration.zero);
      expect(heavy.map((m) => m['type']), ['tree:update']);

      await heavySub.cancel();
      await statusSub.cancel();
      await session.close();
    },
  );

  test(
    'a preview-channel tunnel frame never reaches a checkout heavy stream',
    () async {
      final transport = FakeAgentTransport();
      final session = await _openSession(transport);

      final received = <Map<String, dynamic>>[];
      final sub = session.checkoutHeavyStream('checkout-a').listen(received.add);
      await Future<void>.delayed(Duration.zero);

      // Documentation of the shape the gate exists for, NOT the negative that
      // proves it: `tunnel:http-chunk` classifies as MessageTier.ignore, so the
      // classifier drops it with or without the gate. The test above is the one
      // that fails when the gate widens.
      transport.emitJson({
        'id': '00000000-0000-0000-0000-000000000002',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'tunnel:http-chunk',
        'requestId': 'r1',
        'checkoutId': 'checkout-a',
      }, channel: 'preview');
      await Future<void>.delayed(Duration.zero);

      expect(received, isEmpty);

      await sub.cancel();
      await session.close();
    },
  );
}
