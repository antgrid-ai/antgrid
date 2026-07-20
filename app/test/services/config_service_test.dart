import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/services/config_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    useInMemoryPrefs();
  });

  Future<ProjectSession> newSession(
    FakeAgentTransport t, {
    String projectId = 'p',
  }) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: projectId,
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await t.dispose(),
    );
  }

  test(
    'fromSession subscribes to status; config:changed updates state',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = ConfigService.fromSession(session);

      t.emit('config:changed', {
        'config': {'terminals': const [], 'commands': const []},
      });
      await Future<void>.delayed(Duration.zero);

      expect(svc.currentState.config, isNotNull);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'read() sends config:read and completes on config:read-result',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t, projectId: 'proj-q');
      final svc = ConfigService.fromSession(session);

      final fut = svc.read();
      await Future<void>.delayed(Duration.zero);

      final sent = t.sent.firstWhere((m) => m['type'] == 'config:read');
      expect(sent, isNotNull);
      expect(svc.currentState.loading, isTrue);

      t.emit('config:read-result', {
        'ok': true,
        'config': {'terminals': const [], 'commands': const []},
      });

      final cfg = await fut;
      expect(cfg, isNotNull);
      expect(svc.currentState.loading, isFalse);

      await svc.dispose();
      await session.close();
    },
  );

  test('dispose is idempotent and fails pending requests', () async {
    final t = FakeAgentTransport();
    final session = await newSession(t);
    final svc = ConfigService.fromSession(session);

    final fut = svc.read();
    // Attach an error handler before dispose so the StateError isn't seen as
    // unhandled; we expect it via the explicit check below.
    final expectation = expectLater(fut, throwsA(isA<StateError>()));
    await Future<void>.delayed(Duration.zero);

    await svc.dispose();
    await svc.dispose(); // idempotent

    await expectation;

    await session.close();
  });
}
