import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_hello.dart';
import 'package:antgrid/services/push_identity.dart';
import 'package:antgrid/services/push_messaging_service.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_status.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

/// A relay session is "ready" for push:register only once its transport has
/// handshaken (agentHello landed) — mirror that in tests.
const _connected = ProjectStatus(agentHello: AgentHello(version: '0'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  test(
    'registerToken sends push:register with token+provider+pushPubkey on each session',
    () async {
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p',
        transport: t,
        // Push is a relay-only concern — registerToken now skips local
        // sessions, so this session must be relay-mode to be registered.
        mode: ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async => t.dispose(),
      );
      session.status.hydrate(_connected); // transport handshaken
      final svc = PushMessagingService();
      await svc.registerToken(
        token: 'fcm-tok',
        pushIdentity: PushIdentity.inMemory(),
        sessions: [session],
      );

      final sent = t.sent.where((m) => m['type'] == 'push:register').toList();
      expect(sent, hasLength(1));
      expect(sent.first['pushToken'], 'fcm-tok');
      expect(sent.first['provider'], 'fcm');
      expect((sent.first['pushPubkey'] as String).isNotEmpty, true);
      await session.close();
    },
  );

  test(
    'registerToken defers on a not-yet-connected session, then registers once it handshakes',
    () async {
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'p',
        transport: t,
        mode: ProjectSessionMode.relay,
        cachedSessionsStore: cache,
        onClose: () async => t.dispose(),
      );
      final svc = PushMessagingService();
      // No agentHello yet: a send now would be silently dropped by the
      // still-handshaking transport, so registration must defer (not mark done).
      await svc.registerToken(
        token: 'fcm-tok',
        pushIdentity: PushIdentity.inMemory(),
        sessions: [session],
      );
      expect(t.sent.where((m) => m['type'] == 'push:register'), isEmpty);

      // Agent handshakes → the deferred one-shot registration fires exactly once.
      session.status.hydrate(_connected);
      // Let the listener's async ensureKeypair()+send settle.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sent = t.sent.where((m) => m['type'] == 'push:register').toList();
      expect(sent, hasLength(1));
      expect(sent.first['pushToken'], 'fcm-tok');
      await session.close();
    },
  );

  test('registerToken skips local sessions', () async {
    final t = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    );
    await PushMessagingService().registerToken(
      token: 'fcm-tok',
      pushIdentity: PushIdentity.inMemory(),
      sessions: [session],
    );
    expect(t.sent.where((m) => m['type'] == 'push:register'), isEmpty);
    await session.close();
  });

  test('clearToken sends push:register with empty token', () async {
    final t = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: 'p',
      transport: t,
      mode: ProjectSessionMode.relay,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    );
    await PushMessagingService().clearToken(sessions: [session]);
    final sent = t.sent.where((m) => m['type'] == 'push:register').toList();
    expect(sent.single['pushToken'], '');
    await session.close();
  });
}
