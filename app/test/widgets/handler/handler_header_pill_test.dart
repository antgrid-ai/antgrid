// The agent-header Handler pill for a parked session. A park is the one run
// state with no call to action, so it must read as status and stay inert.
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

HandlerSessionState _session(
  String terminalId, {
  HandlerRunState runState = HandlerRunState.parked,
  int pendingEscalations = 0,
  String? parkKind,
  int? parkedUntil,
}) => HandlerSessionState(
  terminalId: terminalId,
  runState: runState,
  pendingEscalations: pendingEscalations,
  armedAt: 1,
  goal: 'summary',
  backlog: const [],
  escalations: const [],
  parkKind: parkKind,
  parkedUntil: parkedUntil,
);

SessionEntry _entry(String id, {bool deleting = false}) => SessionEntry(
  id: id,
  name: id,
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: false,
  deleting: deleting,
);

/// Focuses `t1` and renders the real production header control over
/// [sessions]. No project is focused, so the handler service stays null —
/// the pill derivation is all this exercises.
Future<void> _pump(
  WidgetTester tester,
  Map<String, HandlerSessionState> sessions,
) async {
  // The control reads first-run state while nothing is armed in focus (the
  // labeled-shield decision), which happens on the pre-emission first frame
  // here even though every case focuses an armed session.
  useInMemoryPrefs();
  final store = await FirstRunStore.open();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        firstRunStoreProvider.overrideWithValue(store),
        activeSessionIdProvider.overrideWith(() => ValueController('t1')),
        selectedRegistrationIdProvider.overrideWith((_) => null),
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(
            const HandlerState.initial().copyWith(sessions: sessions),
          ),
        ),
      ],
      child: const MaterialApp(home: Scaffold(body: HandlerHeaderControl())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a parked session shows its wake time', (tester) async {
    final today = DateTime.now();
    final until = DateTime(today.year, today.month, today.day, 14, 5);
    await _pump(tester, {
      't1': _session(
        't1',
        parkKind: 'limit',
        parkedUntil: until.millisecondsSinceEpoch,
      ),
    });
    expect(find.text('PAUSED · UNTIL 14:05'), findsOneWidget);
  });

  // Day-aware, like the Handler card's own park note: a bare `05:00` on a
  // deadline that is actually tomorrow reads as one the session already blew.
  testWidgets('a wake time on another day carries its date', (tester) async {
    final until = DateTime.now().add(const Duration(days: 1));
    await _pump(tester, {
      't1': _session(
        't1',
        parkKind: 'limit',
        parkedUntil: DateTime(
          until.year,
          until.month,
          until.day,
          5,
        ).millisecondsSinceEpoch,
      ),
    });
    expect(find.textContaining('PAUSED · UNTIL '), findsOneWidget);
    expect(find.textContaining('05:00'), findsOneWidget);
    expect(find.text('PAUSED · UNTIL 05:00'), findsNothing);
  });

  testWidgets('a park with no deadline shows a bare label', (tester) async {
    await _pump(tester, {'t1': _session('t1', parkKind: 'outage')});
    expect(find.text('PAUSED'), findsOneWidget);
  });

  testWidgets('an escalation elsewhere still outranks a parked pill', (
    tester,
  ) async {
    // A parked session must never hide another session's unanswered question.
    await _pump(tester, {
      't1': _session('t1', parkKind: 'limit'),
      't2': _session(
        't2',
        runState: HandlerRunState.needsYou,
        pendingEscalations: 2,
      ),
    });
    expect(find.text('NEEDS YOU 2'), findsOneWidget);
  });

  group('the pill that counts another session', () {
    HandlerEscalation esc(
      String terminalId,
      int i, {
      String urgency = 'normal',
      int at = 1,
    }) => HandlerEscalation(
      escalationId: '$terminalId-$i',
      terminalId: terminalId,
      question: 'q',
      reasoning: 'r',
      draftReply: 'd',
      urgency: urgency,
      at: at,
    );

    /// Same control, but over a container the test keeps, so the tap's effect
    /// on focus and on the pending destination is readable.
    Future<ProviderContainer> pumpWithContainer(
      WidgetTester tester,
      Map<String, HandlerSessionState> sessions, {
      required String focused,
      required void Function() onReveal,
      List<HandlerEscalation>? escalations,
      List<SessionEntry>? entries,
    }) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      final container = ProviderContainer(
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          // Given `entries`, focus is written through the REAL ActiveSessionId
          // so its deleting-session guard is live; otherwise a pre-seeded plain
          // controller stands in and the guard is out of scope.
          if (entries == null)
            activeSessionIdProvider.overrideWith(() => ValueController(focused))
          else
            freshSessionsStateProvider.overrideWithValue(
              SessionsState(projectId: 'p1', sessions: entries),
            ),
          selectedRegistrationIdProvider.overrideWith((_) => null),
          revealHandlerTabProvider.overrideWith(
            () => ValueController<VoidCallback?>(onReveal),
          ),
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(
              HandlerState.initial().copyWith(
                sessions: sessions,
                escalations:
                    escalations ??
                    [
                      for (final s in sessions.values)
                        for (var i = 0; i < s.pendingEscalations; i++)
                          esc(s.terminalId, i),
                    ],
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      if (entries != null) {
        container.read(activeSessionIdProvider.notifier).set(focused);
      }
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: HandlerHeaderControl()),
          ),
        ),
      );
      await tester.pump();
      return container;
    }

    testWidgets('focuses that session, and hands the tab over as pending', (
      tester,
    ) async {
      // The tab renders the focused session only, so revealing it without
      // moving focus lands the user on an empty tab — the one navigation this
      // pill exists to make. It goes through the pending handover rather than
      // the reveal callback because the focus write it just made arms the
      // shell's per-session UI restore, which undoes a tab selected before it.
      var revealed = false;
      final container = await pumpWithContainer(
        tester,
        {
          't1': _session('t1', runState: HandlerRunState.watching),
          't2': _session(
            't2',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
        },
        focused: 't1',
        onReveal: () => revealed = true,
      );

      expect(find.text('NEEDS YOU 1'), findsOneWidget);
      await tester.tap(find.text('NEEDS YOU 1'));
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 't2');
      expect(
        container.read(pendingWorkspaceViewProvider)?.value,
        WorkspaceView.handler,
      );
      expect(revealed, isFalse);
    });

    // The control lands on the handler tab by handover or by call, and the
    // agent-page drain runs LAST — so a stamp a notification route left
    // pending would override the tab on the very frame this opens it.
    testWidgets('drops an agent-page stamp an earlier route left pending', (
      tester,
    ) async {
      final container = await pumpWithContainer(
        tester,
        {
          't1': _session('t1', runState: HandlerRunState.watching),
          't2': _session(
            't2',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
        },
        focused: 't1',
        onReveal: () {},
      );
      container.read(pendingAgentPageProvider.notifier).set((
        target: null,
        value: true,
      ));

      await tester.tap(find.text('NEEDS YOU 1'));
      await tester.pump();

      expect(container.read(pendingAgentPageProvider), isNull);
      expect(
        container.read(pendingWorkspaceViewProvider)?.value,
        WorkspaceView.handler,
      );
    });

    testWidgets('leaves focus alone when the focused session is the one '
        'waiting', (tester) async {
      var revealed = false;
      final container = await pumpWithContainer(
        tester,
        {
          't1': _session(
            't1',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
        },
        focused: 't1',
        onReveal: () => revealed = true,
      );

      await tester.tap(find.text('NEEDS YOU 1'));
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 't1');
      expect(revealed, isTrue);
    });

    testWidgets('an urgent question elsewhere does not steal a session its '
        'own pill was counting', (tester) async {
      // `escalations` is banded by urgency across the whole project, so its
      // head is not the row the pill was labelled from whenever the focused
      // session has a question of its own — and a status pill must never
      // switch the user's whole workspace to a session they did not pick.
      var revealed = false;
      final container = await pumpWithContainer(
        tester,
        {
          't1': _session(
            't1',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
          't2': _session(
            't2',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
        },
        focused: 't1',
        escalations: [esc('t2', 0, urgency: 'high'), esc('t1', 0, at: 2)],
        onReveal: () => revealed = true,
      );

      expect(find.text('NEEDS YOU 1'), findsOneWidget);
      await tester.tap(find.text('NEEDS YOU 1'));
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 't1');
      expect(revealed, isTrue);
    });

    testWidgets('lands on a session the pill counted, not the oldest row on '
        'the project', (tester) async {
      // The mirror case: the focused session is not the one being counted, so
      // the target has to come from the OTHER sessions' rows however the
      // project-wide list happens to be ordered.
      final container = await pumpWithContainer(
        tester,
        {
          't1': _session(
            't1',
            runState: HandlerRunState.parked,
            pendingEscalations: 1,
          ),
          't2': _session(
            't2',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
        },
        focused: 't1',
        escalations: [esc('t1', 0), esc('t2', 0, at: 2)],
        onReveal: () {},
      );

      expect(find.text('NEEDS YOU 1'), findsOneWidget);
      await tester.tap(find.text('NEEDS YOU 1'));
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 't2');
    });

    testWidgets('a target the bridge is already deleting keeps the focus it '
        'has and the tab that answers for it', (tester) async {
      // `ActiveSessionId.set` refuses a deleting session, and such a session
      // keeps its replayed escalations for the seconds before its row goes —
      // so the pill can name a target the write will not take. Handing the tab
      // over as pending regardless would stamp the session still in focus with
      // a destination chosen for the other one.
      var revealed = false;
      final container = await pumpWithContainer(
        tester,
        {
          't1': _session('t1', runState: HandlerRunState.watching),
          't2': _session(
            't2',
            runState: HandlerRunState.needsYou,
            pendingEscalations: 1,
          ),
        },
        focused: 't1',
        entries: [_entry('t1'), _entry('t2', deleting: true)],
        onReveal: () => revealed = true,
      );

      expect(find.text('NEEDS YOU 1'), findsOneWidget);
      await tester.tap(find.text('NEEDS YOU 1'));
      await tester.pump();

      expect(container.read(activeSessionIdProvider), 't1');
      expect(container.read(pendingWorkspaceViewProvider), isNull);
      expect(revealed, isTrue);
    });
  });
}
