// The app's only reading of an isolated session's provisioning run. Everything
// the feature renders — the workspace banner, the drawer/Recent badge, the
// bootstrap's double-start guard — is derived here, so the two things that make
// it honest are pinned: an unnameable state degrades rather than being guessed
// at, and the projection reads the LIVE list and never the persisted cache.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/cached_sessions.dart';
import 'package:antgrid/providers/session_setup.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _projectId = 'P';

SessionSetup _setup(String state, {bool pendingStart = false}) => SessionSetup(
  state: state,
  stepIndex: 1,
  stepCount: 4,
  startedAt: 1,
  pendingStart: pendingStart,
);

SessionEntry _entry(String id, {SessionSetup? setup}) => SessionEntry(
  id: id,
  name: id,
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  checkoutId: 'worktree-1',
  checkoutKind: 'managed-worktree',
  setup: setup,
);

ProviderContainer _container({
  List<SessionEntry>? live,
  List<SessionEntry> cached = const [],
}) {
  final container = ProviderContainer(
    overrides: [
      selectedRegistrationIdProvider.overrideWith((ref) => _projectId),
      freshSessionsStateProvider.overrideWithValue(
        live == null
            ? null
            : SessionsState(projectId: _projectId, sessions: live),
      ),
      cachedSessionsProvider(_projectId).overrideWith((ref) => cached),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sessionSetupPhase', () {
    test('names every state the bridge declares', () {
      expect(sessionSetupPhase(_setup('running')), SessionSetupPhase.running);
      expect(sessionSetupPhase(_setup('done')), SessionSetupPhase.done);
      expect(sessionSetupPhase(_setup('failed')), SessionSetupPhase.failed);
      expect(sessionSetupPhase(_setup('skipped')), SessionSetupPhase.skipped);
      expect(
        sessionSetupPhase(_setup('interrupted')),
        SessionSetupPhase.interrupted,
      );
    });

    // The bridge owns this vocabulary and may widen it, so a value this build
    // cannot name has to degrade to the weakest true statement rather than be
    // read as either finished or still going.
    test('degrades a state it cannot name, and a session with none', () {
      expect(sessionSetupPhase(_setup('restoring')), SessionSetupPhase.unknown);
      expect(sessionSetupPhase(null), SessionSetupPhase.unknown);
    });
  });

  group('sessionSetupProvider', () {
    test('projects the live entry', () {
      final c = _container(live: [_entry('a', setup: _setup('running'))]);
      expect(c.read(sessionSetupProvider('a'))?.state, 'running');
      expect(c.read(sessionSetupProvider('missing')), isNull);
    });

    // The cache deliberately carries no `setup`, but nothing stops a row it
    // serves from claiming one. Sourcing this from the live list alone is what
    // stops a restored `running` painting a banner nothing is left to finish.
    test('never answers from the persisted cache', () {
      final c = _container(
        live: null,
        cached: [_entry('a', setup: _setup('running'))],
      );

      // The cached row really does carry a run — and the projection still says
      // nothing, because there is no live list behind it to finish one.
      expect(
        c.read(cachedSessionsProvider(_projectId)).single.setup,
        isNotNull,
      );
      expect(c.read(sessionSetupProvider('a')), isNull);
    });

    test('follows the active session', () {
      final c = _container(
        live: [
          _entry('a', setup: _setup('running')),
          _entry('b', setup: _setup('failed')),
        ],
      );

      expect(c.read(activeSessionSetupProvider), isNull);
      c.read(activeSessionIdProvider.notifier).set('b');
      expect(c.read(activeSessionSetupProvider)?.state, 'failed');
    });
  });

  group('sessionStartQueued', () {
    // Load-bearing wherever a stopped session is auto-started: a queued session
    // reports `running: false` for the whole run, so `running` alone reads as
    // "needs starting" and sends a second start carrying no initialPrompt —
    // which replaces the one the user actually typed.
    test('is true only while a start is waiting behind the run', () {
      expect(sessionStartQueued(_setup('running', pendingStart: true)), isTrue);
      expect(sessionStartQueued(_setup('running')), isFalse);
      expect(sessionStartQueued(_setup('done')), isFalse);
      expect(sessionStartQueued(null), isFalse);
    });

    test('reads through the provider for a live session', () {
      final c = _container(
        live: [_entry('a', setup: _setup('running', pendingStart: true))],
      );

      expect(c.read(sessionStartQueuedProvider('a')), isTrue);
      expect(c.read(sessionStartQueuedProvider('missing')), isFalse);
    });
  });

  // The callers are `void` tap handlers, where an escaping rejection reaches
  // PlatformDispatcher.onError as a fatal.
  test(
    'runSessionSetupAction reports an unreachable project, never throws',
    () async {
      final c = _container(live: const []);

      final result = await runSessionSetupAction(
        c,
        entryId: 'nothing-warm-here',
        sessionId: 'a',
        action: SessionSetupAction.skip,
      );

      expect(result.ok, isFalse);
      expect(result.error, isNotEmpty);
    },
  );
}
