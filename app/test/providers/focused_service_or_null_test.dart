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

  // warmServiceFor is the counterpart every explicit user action goes through:
  // the windows where the synchronous read above answers null are exactly when a
  // Start button or a rename is pressed, so it waits the project out instead of
  // dropping the action.
  group('warmServiceFor', () {
    test('waits out a session that is still resolving', () async {
      final session = await _buildFakeSession();
      final pending = Completer<ProjectSession>();
      final c = ProviderContainer(
        overrides: [
          projectSessionProvider('test').overrideWith((ref) => pending.future),
        ],
      );
      addTearDown(c.dispose);

      final pick = warmServiceFor(c, 'test', (s) => s.sessionsService);
      // Still unresolved: the synchronous twin would have answered null here.
      expect(focusedServiceOrNull(c, (s) => s.sessionsService), isNull);

      pending.complete(session);
      expect(await pick, same(session.sessionsService));
    });

    test('resolves an entry that is NOT the focused project', () async {
      final other = await _buildFakeSession();
      final c = ProviderContainer(
        overrides: [
          selectedRegistrationIdProvider.overrideWithValue('focused'),
          projectSessionProvider('other').overrideWith((ref) async => other),
        ],
      );
      addTearDown(c.dispose);

      // The point of the explicit entryId: a drawer row or a dialog outliving
      // its focus must reach ITS project, not whichever one is focused.
      expect(
        await warmServiceFor(c, 'other', (s) => s.sessionsService),
        same(other.sessionsService),
      );
    });

    test('returns null once the timeout is out rather than hanging', () async {
      final c = ProviderContainer(
        overrides: [
          // Never completes — an unreachable agent.
          projectSessionProvider(
            'test',
          ).overrideWith((ref) => Completer<ProjectSession>().future),
        ],
      );
      addTearDown(c.dispose);

      expect(
        await warmServiceFor(
          c,
          'test',
          (s) => s.sessionsService,
          timeout: const Duration(milliseconds: 20),
        ),
        isNull,
      );
    });

    test('returns null when the project fails to open', () async {
      final c = ProviderContainer(
        overrides: [
          projectSessionProvider(
            'test',
          ).overrideWith((ref) async => throw StateError('no transport')),
        ],
      );
      addTearDown(c.dispose);

      expect(await warmServiceFor(c, 'test', (s) => s.sessionsService), isNull);
    });
  });
}
