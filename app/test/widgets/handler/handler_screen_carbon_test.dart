// The Handler screen is a Carbon surface: nothing under its scope may build an
// Ab widget, in any state, density or brightness. Each state below is the one
// most likely to have kept a stray Ab helper.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/handler/handler_screen.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/carbon_guard.dart';

const _choices = [
  HandlerEscalationChoice(choiceId: 'approve', label: 'Approve', text: 'yes'),
  HandlerEscalationChoice(choiceId: 'reject', label: 'Reject', text: 'no'),
];

const _escalations = [
  HandlerEscalation(
    escalationId: 'e1',
    terminalId: 't1',
    question: 'bun or vitest?',
    reasoning: 'Affects CI wiring.',
    draftReply: 'use bun',
    urgency: 'high',
    at: 1,
    choices: _choices,
  ),
  HandlerEscalation(
    escalationId: 'e2',
    terminalId: 't1',
    question: 'delete the build folder?',
    reasoning: 'It is large.',
    draftReply: 'no',
    urgency: 'normal',
    floorRule: 'rm -rf',
    at: 2,
  ),
];

const _session = HandlerSessionState(
  terminalId: 't1',
  runState: HandlerRunState.needsYou,
  pendingEscalations: 2,
  armedAt: 1,
  goal: 'ship it',
  backlog: [
    HandlerInstructionItem(id: 'a', text: 'run the tests', status: 'active', createdAt: 1),
    HandlerInstructionItem(id: 'b', text: 'open a PR', status: 'queued', createdAt: 2),
  ],
  escalations: _escalations,
);

const _loaded = HandlerState(
  defaultTool: null,
  lenses: null,
  sessions: {'t1': _session},
  escalations: _escalations,
  activity: [
    HandlerActivityRecord(
      recordId: 'r1',
      at: 1,
      terminalId: 't1',
      decision: 'handle',
      reason: 'auto-answered the lint prompt',
    ),
    HandlerActivityRecord(
      recordId: 'r2',
      at: 2,
      terminalId: 't1',
      decision: 'floor_warning',
      reason: 'rm -rf',
    ),
  ],
  snapshots: [
    HandlerSnapshot(
      snapshotId: 's1',
      terminalId: 't1',
      at: 1,
      action: 'force_push',
      trigger: 'git push --force origin feat/x',
      summary: 'pre-push SHA abc1234 recorded',
      state: 'available',
    ),
  ],
  wrapUps: [
    HandlerWrapUp(
      wrapUpId: 'w1',
      terminalId: 't1',
      at: 1,
      goal: 'ship it',
      outcomes: [
        HandlerWrapUpOutcome(status: 'done', total: 1, items: ['run tests']),
      ],
      blockedTotal: 0,
      blockedReasons: [],
    ),
  ],
);

void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    HandlerState state, {
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith((ref) => Stream.value(state)),
          activeSessionIdProvider.overrideWith(() => ValueController('t1')),
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(body: HandlerScreen()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final brightness in Brightness.values) {
      testWidgets('loaded screen builds no Ab widget (${platform.name}, '
          '${brightness.name})', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await pumpScreen(tester, _loaded, brightness: brightness);

          expect(find.byType(AbCarbonScope), findsOneWidget);
          expect(find.text('bun or vitest?'), findsWidgets);
          expect(abWidgetsInScope(tester), isEmpty);

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('the off state builds no Ab widget', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpScreen(tester, const HandlerState.initial());

      expect(find.textContaining('Handler is off'), findsOneWidget);
      expect(abWidgetsInScope(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('an armed session with nothing yet builds no Ab widget', (
    tester,
  ) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpScreen(
        tester,
        const HandlerState(
          defaultTool: null,
          lenses: null,
          escalations: [],
          activity: [],
          sessions: {
            't1': HandlerSessionState(
              terminalId: 't1',
              runState: HandlerRunState.watching,
              pendingEscalations: 0,
              armedAt: 1,
              goal: 'ship it',
              backlog: [],
              escalations: [],
            ),
          },
        ),
      );

      expect(abWidgetsInScope(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('a failed history load builds no Ab widget', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpScreen(
        tester,
        const HandlerState(
          defaultTool: null,
          lenses: null,
          sessions: {'t1': _session},
          escalations: _escalations,
          activity: [],
          activityHistoryError: 'history unavailable',
        ),
      );

      expect(abWidgetsInScope(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the open session menu builds no Ab widget', (tester) async {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpScreen(tester, _loaded);

      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is CarbonOverflowMenu && w.semanticLabel == 'Handler options',
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Disarm Handler'), findsOneWidget);
      expect(abWidgetsInScope(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
