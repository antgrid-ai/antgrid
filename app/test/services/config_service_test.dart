import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/models/ab_config.dart';
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

  test(
    'read() throws with an error state when the reply never comes — '
    'never hangs forever, never looks like an empty config',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = ConfigService.fromSession(
        session,
        requestTimeout: const Duration(milliseconds: 50),
      );

      // No config:read-result is ever emitted. The outer guard is the test's
      // hang detector: before the fix this future never completed. Resolving to
      // null would be worse than hanging — the settings screen reads null as
      // "no config yet" and Save would overwrite the project's real
      // antgrid.yaml with an empty draft.
      await expectLater(
        svc.read().timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );
      expect(svc.currentState.loading, isFalse,
          reason: 'a timed-out read must not leave the UI spinner on');
      expect(svc.currentState.error, isNotNull);

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'save() throws when the reply never comes',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = ConfigService.fromSession(
        session,
        requestTimeout: const Duration(milliseconds: 50),
      );

      // null means success and a non-empty list means the agent rejected the
      // write; a lost reply is neither, so it must not resolve at all.
      await expectLater(
        svc.save(const AbConfig()).timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );

      await svc.dispose();
      await session.close();
    },
  );

  test(
    'detectTools() throws when the reply never comes — an empty list means '
    'the agent answered "none installed"',
    () async {
      final t = FakeAgentTransport();
      final session = await newSession(t);
      final svc = ConfigService.fromSession(
        session,
        requestTimeout: const Duration(milliseconds: 50),
      );

      await expectLater(
        svc.detectTools().timeout(const Duration(seconds: 2)),
        throwsA(isA<TimeoutException>()),
      );

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
