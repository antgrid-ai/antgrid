// D-B2: activation follows focus. checkoutActivationBinderProvider is the
// keep-alive binder that applies ProjectSession.setActiveCheckouts for the
// focused project's focused checkout — mirroring agentFocusBinderProvider's
// shape (a side-effecting Provider<void> build, watched rather than listened
// to) for the same reason: a `read` of a dirty dependency inside a `listen`
// callback can force a rejected mid-frame rebuild.

import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<ProjectSession> makeSession(FakeAgentTransport t) async {
    final cache = await CachedSessionsStore.open();
    return ProjectSession(
      projectId: 'A',
      transport: t,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => t.dispose(),
    );
  }

  test('with no active session row the binder activates main', () async {
    final t = FakeAgentTransport();
    final session = await makeSession(t);
    addTearDown(session.close);

    final container = ProviderContainer(
      overrides: [
        projectSessionProvider.overrideWith((ref, id) async => session),
        selectedRegistrationIdProvider.overrideWithValue('A'),
        activeSessionProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider('A').future);

    container.read(checkoutActivationBinderProvider);
    await Future<void>.delayed(Duration.zero);

    expect(session.activeCheckouts, {'main'});
  });

  test(
    'an isolated session row activates its own checkout, deactivating main',
    () async {
      final t = FakeAgentTransport();
      final session = await makeSession(t);
      addTearDown(session.close);
      // Main starts active — the binder must MOVE activation onto the
      // isolated checkout, not merely add to it.
      session.setActiveCheckouts({'main'});

      final entry = SessionEntry(
        id: 'session-1',
        name: 'Session',
        createdAt: 1,
        lastUsedAt: 1,
        archived: false,
        running: true,
        checkoutId: 'wt1',
        checkoutKind: 'managed-worktree',
        checkoutBranch: 'antgrid/session-1',
      );

      final container = ProviderContainer(
        overrides: [
          projectSessionProvider.overrideWith((ref, id) async => session),
          selectedRegistrationIdProvider.overrideWithValue('A'),
          activeSessionProvider.overrideWithValue(entry),
        ],
      );
      addTearDown(container.dispose);
      await container.read(projectSessionProvider('A').future);

      container.read(checkoutActivationBinderProvider);
      await Future<void>.delayed(Duration.zero);

      expect(session.activeCheckouts, {'wt1'});
      expect(session.existingServicesForCheckout('main')!.isActive, isFalse);
    },
  );
}
