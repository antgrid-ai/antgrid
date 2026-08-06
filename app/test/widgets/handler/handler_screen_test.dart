import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/handler/handler_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

HandlerSessionState sessionState(
  String terminalId, {
  String? judgeTool,
  String? judgeModel,
  HandlerObservability? observability,
}) => HandlerSessionState(
  terminalId: terminalId,
  notifyOnly: false,
  runState: HandlerRunState.watching,
  pendingEscalations: 0,
  armedAt: 1,
  doneWhenMet: false,
  brief: const HandlerBrief(
    taskSummary: 'summary',
    willHandle: [],
    wakeFor: [],
    thenItems: [],
  ),
  ledger: const [],
  escalations: const [],
  judgeTool: judgeTool,
  judgeModel: judgeModel,
  observability: observability,
);

HandlerState stateWith({
  String? defaultTool,
  required Map<String, HandlerSessionState> sessions,
}) => HandlerState.initial().copyWith(
  defaultTool: defaultTool,
  sessions: sessions,
);

Future<void> pumpHandlerScreen(WidgetTester tester, HandlerState state) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        handlerStateProvider.overrideWith((ref) => Stream.value(state)),
      ],
      child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('off Handler shows the disabled empty state', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(const HandlerState.initial()),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Handler is off'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('pending escalation + activity render in their sections', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const esc = HandlerEscalation(
      escalationId: 'e1',
      terminalId: 't1',
      question: 'bun or vitest?',
      reasoning: 'r',
      draftReply: 'use bun',
      urgency: 'high',
      at: 1,
    );
    const rec = HandlerActivityRecord(
      recordId: 'r1',
      at: 1,
      terminalId: 't1',
      decision: 'handle',
      reason: 'auto-answered the lint prompt',
    );
    const session = HandlerSessionState(
      terminalId: 't1',
      notifyOnly: false,
      runState: HandlerRunState.needsYou,
      pendingEscalations: 1,
      armedAt: 1,
      doneWhenMet: false,
      brief: HandlerBrief(
        taskSummary: '',
        willHandle: [],
        wakeFor: [],
        thenItems: [],
      ),
      ledger: [],
      escalations: [esc],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(
              const HandlerState.initial().copyWith(
                sessions: {'t1': session},
                escalations: [esc],
                activity: [rec],
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
      ),
    );
    await tester.pump();
    expect(find.textContaining('bun or vitest?'), findsOneWidget);
    expect(
      find.textContaining('auto-answered the lint prompt'),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('park and resume render as activity rows', (tester) async {
    final wake = DateTime(2026, 7, 31, 14, 5);
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
        activity: [
          HandlerActivityRecord(
            recordId: 'r1',
            at: 1,
            terminalId: 't1',
            decision: 'parked',
            reason: 'rate_limit',
            detail: wake.toIso8601String(),
          ),
          const HandlerActivityRecord(
            recordId: 'r2',
            at: 2,
            terminalId: 't1',
            decision: 'resumed',
            reason: 'park timer elapsed',
          ),
        ],
      ),
    );
    expect(find.textContaining('Paused: rate_limit'), findsOneWidget);
    expect(find.textContaining('14:05'), findsOneWidget);
    expect(find.textContaining('Resumed: park timer elapsed'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('armed session row shows its judge chip', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1', judgeTool: 'codex')}),
    );
    expect(find.text('codex'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('session without a judge override shows the resolved default', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        defaultTool: 'claude-code',
        sessions: {'t1': sessionState('t1')},
      ),
    );
    expect(find.text('claude-code'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an unwatchable armed session says so on its row', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': sessionState(
            't1',
            observability: HandlerObservability.unsupported,
          ),
        },
      ),
    );
    expect(find.textContaining('Not watched'), findsOneWidget);
    expect(find.text('ESCALATE ONLY'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an escalate-only session reads differently from an unwatchable one', (
    tester,
  ) async {
    // Two distinct facts: this one IS watched and merely has no judge to answer
    // with. Rendering them the same would hide which one the user is looking at.
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': sessionState(
            't1',
            observability: HandlerObservability.escalateOnly,
          ),
        },
      ),
    );
    expect(find.text('ESCALATE ONLY'), findsOneWidget);
    expect(find.textContaining('Not watched'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a session with no reported observability is marked neither way', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}),
    );
    expect(find.textContaining('Not watched'), findsNothing);
    expect(find.text('ESCALATE ONLY'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
