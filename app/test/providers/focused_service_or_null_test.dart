import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

// Companion to service_when_ready_test.dart: that pins the BUILD-time gate,
// this one pins the handler/timer/post-await gate. A focused project id is not
// proof its services exist — focus is written before any session is built (deep
// link, nav back/forward) and a live session is invalidated under a steady focus
// (host restart, LRU evict) — and in those windows the façades throw somewhere
// no `build()` can catch it.

Future<ProjectSession> _buildFakeSession() async {
  useInMemoryPrefs();
  final t = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'test',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => t.dispose(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('returns null when no project is focused', () {
    // No override: the default selection is null, i.e. nothing focused.
    final c = ProviderContainer();
    addTearDown(c.dispose);

    expect(focusedServiceOrNull(c, (s) => s.sessionsService), isNull);
  });

  test('returns null while the focused session is still resolving, where the '
      'façade would throw', () async {
    final session = await _buildFakeSession();
    final pending = Completer<ProjectSession>();
    final c = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => pending.future),
      ],
    );
    addTearDown(c.dispose);

    expect(focusedServiceOrNull(c, (s) => s.sessionsService), isNull);
    // The contract this guards: the same moment through the façade is a throw.
    expect(() => c.read(sessionsServiceProvider), throwsA(anything));

    pending.complete(session);
    await c.read(projectSessionProvider('test').future);

    expect(
      focusedServiceOrNull(c, (s) => s.sessionsService),
      same(session.sessionsService),
    );
  });
}
