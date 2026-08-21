// The session dot's whole vocabulary, in one place: what each work status
// paints, and — the regression this file exists for — what a session AT REST
// paints. Merely opening a session used to fill its dot in the accent (off-white
// on the default preset), so the brightest indicator in the sidebar was the one
// session the user was already looking at. Liveness is not a status.
import 'package:antgrid/design/ab_status_tone.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/services/control_plane_client.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/agent_work_status_dot.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _projectId = 'p';
const _sessionId = 'sess-1';

SessionEntry _entry({required bool running, bool archived = false}) =>
    SessionEntry(
      id: _sessionId,
      name: 'Fix auth bug',
      createdAt: 0,
      lastUsedAt: 0,
      archived: archived,
      running: running,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  group('agentWorkStatusDotSpec', () {
    test('only the live states pulse', () {
      // A dot that breathes claims something is happening right now. `unread`
      // is a fact sitting still, and `error` is over.
      expect(agentWorkStatusDotSpec(AgentWorkStatus.working).pulse, isTrue);
      expect(agentWorkStatusDotSpec(AgentWorkStatus.attention).pulse, isTrue);
      expect(agentWorkStatusDotSpec(AgentWorkStatus.unread).pulse, isFalse);
      expect(agentWorkStatusDotSpec(AgentWorkStatus.error).pulse, isFalse);
      expect(agentWorkStatusDotSpec(AgentWorkStatus.done).pulse, isFalse);
    });

    test('unread is its own blue tone, filled, and done alone is hollow', () {
      final unread = agentWorkStatusDotSpec(AgentWorkStatus.unread);
      expect(unread.tone, AbStatusTone.unread);
      expect(unread.style, AbDotStyle.filled);
      // Not reused from anything else on a session row: `info` is live activity
      // and `warning` is a block, and both already speak for another state.
      expect(unread.tone, isNot(agentWorkStatusDotSpec(AgentWorkStatus.working).tone));
      expect(
        agentWorkStatusDotSpec(AgentWorkStatus.done).style,
        AbDotStyle.hollow,
      );
    });

    test('every wire status has a spec', () {
      for (final s in AgentWorkStatus.values) {
        expect(agentWorkStatusDotSpec(s).tone, isNotNull);
      }
    });
  });

  test('unread round-trips off the wire', () {
    expect(AgentWorkStatus.fromWire('unread'), AgentWorkStatus.unread);
  });

  group('SessionRow leading dot', () {
    /// Pumps the row with [status] published on the same per-session advert map
    /// a real bridge fills, so the dot is reached the way production reaches it.
    Future<AbStatusDot> pumpDot(
      WidgetTester tester, {
      required bool running,
      bool archived = false,
      AgentWorkStatus? status,
    }) async {
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      final container = ProviderContainer(
        overrides: [
          selectedRegistrationIdProvider.overrideWithValue(_projectId),
          projectSessionProvider.overrideWith((ref, id) async => session),
        ],
      );
      addTearDown(container.dispose);
      await container.read(projectSessionProvider(_projectId).future);
      if (status != null) {
        container
            .read(remoteSessionStatusProvider.notifier)
            .setLocalSessionStatuses({
              _projectId: {_sessionId: status},
            });
      }

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: SessionRow(
                entryId: _projectId,
                session: _entry(running: running, archived: archived),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The slot holds either the bare fallback dot or an AgentWorkStatusDot
      // wrapping one, so match the keyed widget itself as well as its subtree.
      return tester.widget<AbStatusDot>(
        find.descendant(
          of: find.byKey(const ValueKey('session-status-dot-$_sessionId')),
          matching: find.byType(AbStatusDot),
          matchRoot: true,
        ),
      );
    }

    // The regression these two share: `running` used to mean a filled accent
    // dot, so opening a session lit it brighter than one that was actually
    // doing something. Split so each pumps once — a second pumpWidget in one
    // test leaves the first tree's riverpod dispose timer pending.
    testWidgets('a visited, running, idle session is the hollow idle dot', (
      tester,
    ) async {
      final dot = await pumpDot(tester, running: true);
      expect(dot.style, AbDotStyle.hollow);
      expect(dot.tone, AbStatusTone.agentIdle);
    });

    testWidgets('an untouched session paints the same thing', (tester) async {
      final dot = await pumpDot(tester, running: false);
      expect(dot.style, AbDotStyle.hollow);
      expect(dot.tone, AbStatusTone.agentIdle);
    });

    testWidgets('archived is the one at-rest distinction still drawn', (
      tester,
    ) async {
      final dot = await pumpDot(tester, running: false, archived: true);
      expect(dot.tone, AbStatusTone.disabled);
      expect(dot.style, AbDotStyle.hollow);
    });

    testWidgets('an unread answer takes the slot back', (tester) async {
      // Not the fallback dot: the work status owns the slot the moment the
      // agent has something to say, and an unheard answer is something to say.
      final dot = await pumpDot(
        tester,
        running: true,
        status: AgentWorkStatus.unread,
      );
      expect(dot.tone, AbStatusTone.unread);
      expect(dot.style, AbDotStyle.filled);
    });
  });
}
