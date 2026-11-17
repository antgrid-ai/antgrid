// The Handler pieces that live in the agent panel — the PA bar, the away hint
// and the arm sheet — are Carbon surfaces inside an Antgrid-painted panel:
// nothing under their scopes may build an Ab widget, in any state, density or
// brightness, and every sheet they open must find a scope to take its theme
// from.
import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/handler_discovery.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/session_mode.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/handler/handler_arm_explainer.dart';
import 'package:antgrid/widgets/handler/handler_away_hint.dart';
import 'package:antgrid/widgets/handler/handler_backlog_drawer.dart';
import 'package:antgrid/widgets/handler/handler_pa_bar.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/carbon_guard.dart';
import '../../helpers/prefs_test_mock.dart';

const _escalation = HandlerEscalation(
  escalationId: 'e1',
  terminalId: 't1',
  question: 'proceed?',
  reasoning: 'because',
  draftReply: 'yes',
  urgency: 'normal',
  at: 1,
);

const _armed = HandlerSessionState(
  terminalId: 't1',
  runState: HandlerRunState.needsYou,
  pendingEscalations: 1,
  armedAt: 1,
  goal: 'ship it',
  backlog: [
    HandlerInstructionItem(
      id: 'a',
      text: 'run the tests',
      status: 'active',
      createdAt: 1,
    ),
  ],
  escalations: [_escalation],
  brief: 'watch the migrations',
);

HandlerState _state({Map<String, HandlerSessionState> sessions = const {}}) =>
    const HandlerState.initial().copyWith(
      sessions: sessions,
      lenses: const ['pm', 'qa', 'critic', 'release'],
    );

void main() {
  Future<void> pumpApp(
    WidgetTester tester,
    Widget child, {
    required HandlerState state,
    required Brightness brightness,
    List<Override> extra = const [],
  }) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    useInMemoryPrefs();
    final firstRun = await FirstRunStore.open();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          firstRunStoreProvider.overrideWithValue(firstRun),
          activeSessionIdProvider.overrideWith(() => ValueController('t1')),
          activeSessionModeProvider.overrideWithValue('terminal'),
          handlerStateProvider.overrideWith((ref) => Stream.value(state)),
          ...extra,
        ],
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          themeAnimationDuration: Duration.zero,
          home: Scaffold(
            body: Column(
              children: [
                const Expanded(child: SizedBox.shrink()),
                child,
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Finder scopeOf(Type host) => find.descendant(
    of: find.byType(host),
    matching: find.byType(AbCarbonScope),
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final brightness in Brightness.values) {
      final label = '${platform.name}, ${brightness.name}';

      testWidgets('PA bar builds no Ab widget ($label)', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await pumpApp(
            tester,
            const HandlerPaBar(),
            state: _state(sessions: {'t1': _armed}),
            brightness: brightness,
          );

          expect(find.text('proceed?'), findsNothing);
          expect(find.text('Your own'), findsOneWidget);
          expect(
            find.textContaining('Your next message clears this question'),
            findsOneWidget,
          );
          expect(abWidgetsInScope(tester, scope: scopeOf(HandlerPaBar)), isEmpty);

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('away hint builds no Ab widget ($label)', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await pumpApp(
            tester,
            const HandlerAwayHint(),
            state: _state(),
            brightness: brightness,
            extra: [handlerAwayHintProvider.overrideWith((_) => true)],
          );

          expect(find.byType(CarbonNotification), findsOneWidget);
          expect(find.text('Arm'), findsOneWidget);
          expect(
            abWidgetsInScope(tester, scope: scopeOf(HandlerAwayHint)),
            isEmpty,
          );

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });

      testWidgets('arm sheet builds no Ab widget ($label)', (tester) async {
        try {
          debugDefaultTargetPlatformOverride = platform;
          await pumpApp(
            tester,
            AbCarbonScope(
              child: Builder(
                builder: (context) => GestureDetector(
                  onTap: () => showHandlerArmSheet(
                    context,
                    terminalId: 't1',
                    initial: (judgeTool: null, judgeModel: null, lens: null),
                    agentObservable: true,
                    openingPrompt: 'fix the login redirect',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            state: _state(),
            brightness: brightness,
          );
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();

          expect(find.byType(CarbonModal), findsOneWidget);
          expect(find.text('Arm Handler'), findsWidgets);
          expect(
            abWidgetsInScope(tester, scope: find.byType(CarbonModal)),
            isEmpty,
          );

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }

  testWidgets('PA bar without an armed session keeps its scope and shows '
      'nothing', (tester) async {
    await pumpApp(
      tester,
      const HandlerPaBar(),
      state: _state(),
      brightness: Brightness.light,
    );

    expect(scopeOf(HandlerPaBar), findsOneWidget);
    expect(find.byType(CarbonTag), findsNothing);
    expect(abWidgetsInScope(tester, scope: scopeOf(HandlerPaBar)), isEmpty);
  });

  testWidgets('away hint hides inside a scope that stays mounted', (
    tester,
  ) async {
    await pumpApp(
      tester,
      const HandlerAwayHint(),
      state: _state(),
      brightness: Brightness.light,
      extra: [handlerAwayHintProvider.overrideWith((_) => false)],
    );

    expect(scopeOf(HandlerAwayHint), findsOneWidget);
    expect(find.byType(CarbonNotification), findsNothing);
  });

  testWidgets('the PA bar presents the backlog from its own scope', (
    tester,
  ) async {
    await pumpApp(
      tester,
      const HandlerPaBar(),
      state: _state(sessions: {'t1': _armed}),
      brightness: Brightness.dark,
    );

    await tester.tap(find.textContaining('Needs you'));
    await tester.pumpAndSettle();

    expect(find.byType(HandlerBacklogDrawer), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the PA bar presents session settings from its own scope', (
    tester,
  ) async {
    await pumpApp(
      tester,
      const HandlerPaBar(),
      state: _state(sessions: {'t1': _armed}),
      brightness: Brightness.light,
    );

    await tester.tap(find.text('Your own'));
    await tester.pumpAndSettle();

    expect(find.text('Handler settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
