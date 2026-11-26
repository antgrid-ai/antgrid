// The one surface a session that is NOT in focus has. The Handler tab, its tab
// badge and the agent header's pill all answer for the focused session, so a
// sibling's unanswered question is only ever visible here.
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/session_handler_badge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

HandlerSessionState _session(String terminalId, {required int pending}) =>
    HandlerSessionState(
      terminalId: terminalId,
      runState: pending > 0
          ? HandlerRunState.needsYou
          : HandlerRunState.watching,
      pendingEscalations: pending,
      armedAt: 1,
      goal: 'ship it',
      backlog: const [],
      escalations: const [],
    );

Future<void> _pump(
  WidgetTester tester, {
  required String entryId,
  required String sessionId,
  String? focusedProject = 'p',
  Map<String, HandlerSessionState> sessions = const {},
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue(focusedProject),
        handlerStateProvider.overrideWith(
          (ref) =>
              Stream.value(HandlerState.initial().copyWith(sessions: sessions)),
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SessionHandlerBadge(entryId: entryId, sessionId: sessionId),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('counts the answers Handler is waiting on', (tester) async {
    await _pump(
      tester,
      entryId: 'p',
      sessionId: 't2',
      sessions: {'t1': _session('t1', pending: 1), 't2': _session('t2', pending: 2)},
    );
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('says nothing for a session with nothing pending', (
    tester,
  ) async {
    await _pump(
      tester,
      entryId: 'p',
      sessionId: 't1',
      sessions: {'t1': _session('t1', pending: 0)},
    );
    expect(find.byType(SessionHandlerBadge), findsOneWidget);
    expect(find.text('0'), findsNothing);
  });

  testWidgets('says nothing for a session that is not armed at all', (
    tester,
  ) async {
    await _pump(tester, entryId: 'p', sessionId: 'unarmed');
    expect(find.textContaining(RegExp(r'^\d+$')), findsNothing);
  });

  testWidgets('refuses a row belonging to another project', (tester) async {
    // handlerStateProvider follows project focus, so answering this row would
    // attach the FOCUSED project's count to another project's session name —
    // worse than no count. Cross-project escalations need a surface of their
    // own.
    await _pump(
      tester,
      entryId: 'other',
      sessionId: 't2',
      sessions: {'t2': _session('t2', pending: 2)},
    );
    expect(find.text('2'), findsNothing);
  });
}
