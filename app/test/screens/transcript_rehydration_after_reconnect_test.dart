// The blocked screen ("session taken over" → "take back") is only half the
// story: taking the workspace over UNMOUNTS the transcript view, and the retry
// invalidates `projectSessionProvider`, which builds a WHOLE new ProjectSession
// — new transport, new AgentSessionService, empty transcript. Nothing on the
// bridge changes, so the history is still there; the app just never asks for it
// again and the user is left on "Send a message to start" until they leave the
// session and come back.
//
// This drives the real `AgentTranscriptView` over the real service/state
// providers and reproduces the swap with the production trigger — an
// `invalidate` of `projectSessionProvider` — asserting the NEW transport gets a
// `session.transcriptSnapshot`.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/agent_transcript_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _sessionId = 'sess-1';
const _projectId = 'p';

const _entry = SessionEntry(
  id: _sessionId,
  name: 'Session 1',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  mode: 'chat',
  agentSessionId: 'agent-sess-1',
);

// One completed turn, in the frame shape `session.transcriptSnapshot` returns —
// enough that a hydrated view renders history instead of the empty state.
List<Map<String, dynamic>> _historyFrames() => [
  {
    'id': 'f1',
    'timestamp': 0,
    'type': 'agent:turn-start',
    'sessionId': _sessionId,
    'turnId': 't1',
  },
  {
    'id': 'f2',
    'timestamp': 0,
    'type': 'agent:item-added',
    'sessionId': _sessionId,
    'turnId': 't1',
    'item': {'itemId': 'u1', 'kind': 'message', 'role': 'user', 'text': 'hi'},
  },
  {
    'id': 'f3',
    'timestamp': 0,
    'type': 'agent:item-added',
    'sessionId': _sessionId,
    'turnId': 't1',
    'item': {
      'itemId': 'm1',
      'kind': 'message',
      'role': 'assistant',
      'text': 'Hello! How can I help you...',
    },
  },
  {
    'id': 'f4',
    'timestamp': 0,
    'type': 'agent:turn-end',
    'sessionId': _sessionId,
    'turnId': 't1',
    'stopReason': 'end_turn',
  },
];

Future<ProjectSession> _session(
  FakeAgentTransport transport,
  CachedSessionsStore cache,
) async => ProjectSession(
  projectId: _projectId,
  transport: transport,
  mode: ProjectSessionMode.local,
  cachedSessionsStore: cache,
  onClose: () async => await transport.dispose(),
);

int _snapshotCount(FakeAgentTransport t) =>
    t.requests.where((r) => r.method == 'session.transcriptSnapshot').length;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  testWidgets(
    'a reconnect that rebuilds the ProjectSession re-pulls the transcript',
    (tester) async {
      final cache = await CachedSessionsStore.open();
      final before = FakeAgentTransport()
        ..requestHandler = (_, _) => {'frames': _historyFrames()};
      final after = FakeAgentTransport()
        ..requestHandler = (_, _) => {'frames': _historyFrames()};

      // What the retry swaps under the view: same project id, brand new session.
      var current = await _session(before, cache);
      final reconnected = await _session(after, cache);

      final container = ProviderContainer(
        overrides: [
          selectedRegistrationIdProvider.overrideWithValue(_projectId),
          projectSessionProvider.overrideWith((ref, id) async => current),
          activeSessionProvider.overrideWithValue(_entry),
        ],
      );
      addTearDown(container.dispose);
      await container.read(projectSessionProvider(_projectId).future);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: AgentTranscriptView(sessionId: _sessionId)),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        _snapshotCount(before),
        1,
        reason: 'baseline: mounting the view pulls the transcript',
      );
      expect(find.text('Hello! How can I help you...'), findsOneWidget);

      // The "take back" path: retryAgentConnection invalidates the family entry,
      // which builds a fresh ProjectSession over the re-established transport.
      current = reconnected;
      container.invalidate(projectSessionProvider(_projectId));
      await container.read(projectSessionProvider(_projectId).future);
      await tester.pump();
      await tester.pump();

      expect(
        _snapshotCount(after),
        1,
        reason:
            'the new session carries no turns, so a workspace that never '
            're-pulls leaves the user on a blank transcript with intact '
            'history on the bridge',
      );
      expect(find.text('Hello! How can I help you...'), findsOneWidget);
      expect(find.text('Send a message to start'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'the transcript view remounted against the swapped session hydrates it',
    (tester) async {
      // The takeover shape specifically: the blocked screen replaces the
      // workspace, so the view is DISPOSED (deregistering its hydrator) and a
      // fresh State mounts on the way back — against a session that may still
      // be resolving for the first frame.
      final cache = await CachedSessionsStore.open();
      final transport = FakeAgentTransport()
        ..requestHandler = (_, _) => {'frames': _historyFrames()};
      final session = await _session(transport, cache);

      final container = ProviderContainer(
        overrides: [
          selectedRegistrationIdProvider.overrideWithValue(_projectId),
          projectSessionProvider.overrideWith((ref, id) async => session),
          activeSessionProvider.overrideWithValue(_entry),
        ],
      );
      addTearDown(container.dispose);

      Widget tree(bool blocked) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: blocked
                ? const Text('Session taken over')
                : const AgentTranscriptView(sessionId: _sessionId),
          ),
        ),
      );

      // Mounted, hydrated, then taken over.
      await tester.pumpWidget(tree(false));
      await tester.pump();
      await tester.pump();
      expect(_snapshotCount(transport), 1);
      await tester.pumpWidget(tree(true));
      await tester.pump();

      // "Take back": the workspace comes back and must ask again — the service
      // it remounts against is the same instance, but its transcript state was
      // never lost, so this asserts the remount is at least not a regression.
      await tester.pumpWidget(tree(false));
      await tester.pump();
      await tester.pump();
      expect(find.text('Hello! How can I help you...'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
