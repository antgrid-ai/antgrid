// The agent-header Handler pill for a parked session. A park is the one run
// state with no call to action, so it must read as status and stay inert.
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
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
  notifyOnly: false,
  runState: runState,
  pendingEscalations: pendingEscalations,
  armedAt: 1,
  goal: 'summary',
  backlog: const [],
  escalations: const [],
  parkKind: parkKind,
  parkedUntil: parkedUntil,
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
}
