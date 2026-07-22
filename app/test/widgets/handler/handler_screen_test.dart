import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/widgets/handler/handler_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  testWidgets('pending escalation + activity render in their sections',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const esc = HandlerEscalation(
      escalationId: 'e1', terminalId: 't1', question: 'bun or vitest?',
      reasoning: 'r', draftReply: 'use bun', urgency: 'high');
    const rec = HandlerActivityRecord(
      recordId: 'r1', at: 1, terminalId: 't1',
      decision: 'handle', reason: 'auto-answered the lint prompt');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(const HandlerState.initial().copyWith(
              enabled: true,
              runState: HandlerRunState.needsYou,
              pendingEscalations: 1,
              escalations: [esc],
              activity: [rec],
            )),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
      ),
    );
    await tester.pump();
    expect(find.textContaining('bun or vitest?'), findsOneWidget);
    expect(find.textContaining('auto-answered the lint prompt'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
