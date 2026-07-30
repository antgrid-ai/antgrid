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
}
