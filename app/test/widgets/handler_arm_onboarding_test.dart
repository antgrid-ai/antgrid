import 'dart:async';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/handler_discovery.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/session_opening_prompt.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/handler/handler_arm_explainer.dart';
import 'package:antgrid/widgets/handler/handler_away_hint.dart';
import 'package:antgrid/widgets/handler/handler_item_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: ThemeData.dark().copyWith(
        extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
      ),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  group('handlerArmExplainerBody', () {
    const base =
        "Handler watches this session while you're away. When the agent "
        'pauses on a question or a permission, Handler answers what it safely '
        'can and queues the rest for you.';

    test('observable agent gets no coverage line', () {
      expect(handlerArmExplainerBody(agentObservable: true), base);
    });

    test('unwatchable agent appends the unwatchable notice', () {
      final body = handlerArmExplainerBody(
        agentObservable: false,
        agentLabel: 'Claude Code',
      );
      expect(body, startsWith(base));
      expect(body, contains(unwatchableNotice('Claude Code')));
    });

    test('unknown coverage appends the "may stay silent" line', () {
      final body = handlerArmExplainerBody(agentObservable: null);
      expect(body, startsWith(base));
      expect(
        body,
        contains(
          "This agent hasn't reported what Handler can see here, so it may "
          'stay silent.',
        ),
      );
    });

    test('a seeded goal is named, and only when one exists', () {
      const seeded =
          'It starts from what you asked for when you opened this session, '
          'and queues that as your backlog.';
      expect(
        handlerArmExplainerBody(agentObservable: true),
        isNot(contains(seeded)),
      );
      expect(
        handlerArmExplainerBody(agentObservable: true, hasOpeningPrompt: true),
        '$base\n\n$seeded',
      );
    });

    test('a watched session with no headless judge says so before arming', () {
      // The bridge already knows this the moment the session arms and shows it
      // as ESCALATE ONLY on the card — a chip you find by walking away and
      // coming back to a session that woke you for everything.
      final body = handlerArmExplainerBody(
        agentObservable: true,
        judgeCapable: false,
      );
      expect(body, startsWith(base));
      expect(body, endsWith(escalateOnlyNotice));
    });

    test('a headless judge adds nothing', () {
      expect(
        handlerArmExplainerBody(agentObservable: true, judgeCapable: true),
        base,
      );
    });

    test('the judge caveat reads after the seeded goal', () {
      final body = handlerArmExplainerBody(
        agentObservable: true,
        judgeCapable: false,
        hasOpeningPrompt: true,
      );
      expect(body, contains('queues that as your backlog'));
      expect(body, endsWith(escalateOnlyNotice));
    });

    test('an unwatchable agent does not stack a second caveat', () {
      // It reports nothing Handler can act on, so what its judge could have
      // done is moot — and a hedge under the stronger fact only dilutes it.
      final body = handlerArmExplainerBody(
        agentObservable: false,
        agentLabel: 'Claude Code',
        judgeCapable: false,
      );
      expect(body, isNot(contains(escalateOnlyNotice)));
      expect(body, endsWith(unwatchableNotice('Claude Code')));
    });

    test('unknown coverage claims nothing about the judge either', () {
      final body = handlerArmExplainerBody(
        agentObservable: null,
        judgeCapable: null,
      );
      expect(body, isNot(contains(escalateOnlyNotice)));
    });

    test('the coverage warning still reads last', () {
      final body = handlerArmExplainerBody(
        agentObservable: false,
        agentLabel: 'Claude Code',
        hasOpeningPrompt: true,
      );
      expect(body, endsWith(unwatchableNotice('Claude Code')));
    });
  });

  group('handlerShieldTooltip', () {
    // The explainer's copy matrix has its own group above. This is the surface
    // that answers every time, and the two must agree about precedence.
    test('an armed session offers only the way out', () {
      expect(
        handlerShieldTooltip(armed: true, observable: false, judgeCapable: false),
        'Disarm Handler',
      );
    });

    test('an escalate-only agent is named before the arm, not after', () {
      expect(
        handlerShieldTooltip(
          armed: false,
          observable: true,
          judgeCapable: false,
        ),
        escalateOnlyNotice,
      );
    });

    test('unwatchable outranks escalate-only', () {
      // Both true of the same agent says one thing: it reports nothing. What
      // its judge could have done never comes up.
      expect(
        handlerShieldTooltip(
          armed: false,
          observable: false,
          judgeCapable: false,
          agentLabel: 'Claude Code',
        ),
        unwatchableNotice('Claude Code'),
      );
    });

    test('a fully covered agent gets the plain label', () {
      expect(
        handlerShieldTooltip(
          armed: false,
          observable: true,
          judgeCapable: true,
        ),
        'Arm Handler',
      );
    });

    test('an undescribed agent claims neither fault', () {
      expect(
        handlerShieldTooltip(
          armed: false,
          observable: null,
          judgeCapable: null,
        ),
        'Arm Handler',
      );
    });
  });

  group('shieldShowsLabel', () {
    test('labels only before the first arm and never while armed', () {
      expect(shieldShowsLabel(armedOnce: false, sessionArmed: false), isTrue);
      expect(shieldShowsLabel(armedOnce: true, sessionArmed: false), isFalse);
      expect(shieldShowsLabel(armedOnce: false, sessionArmed: true), isFalse);
      expect(shieldShowsLabel(armedOnce: true, sessionArmed: true), isFalse);
    });
  });

  testWidgets('away hint renders its banner and dismiss persists the kill', (
    tester,
  ) async {
    useInMemoryPrefs();
    final store = await FirstRunStore.open();
    await tester.pumpWidget(
      _wrap(
        const HandlerAwayHint(),
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          handlerAwayHintProvider.overrideWith((_) => true),
        ],
      ),
    );
    await tester.pump();

    expect(
      find.text(
        "Still waiting on you — Handler can watch this session and reply "
        "while you're away.",
      ),
      findsOneWidget,
    );
    expect(find.text('ARM'), findsOneWidget);

    await tester.tap(find.byTooltip("Dismiss — won't show again"));
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(HandlerAwayHint)),
    );
    expect(container.read(firstRunProvider).handlerAwayHintDismissed, isTrue);
    expect(store.read().handlerAwayHintDismissed, isTrue);
  });

  group('armWithFirstRunExplainer carries the opening prompt', () {
    /// A REAL [ProjectSession] over a fake transport, focused: the goal is only
    /// proven seeded if the arm the flow sends carries it on the wire, and the
    /// flow resolves its service off the focused project rather than off
    /// anything the caller hands it.
    Future<(FakeAgentTransport, ProviderContainer, BuildContext)> pumpArm(
      WidgetTester tester, {
      required bool armedOnce,
    }) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      if (armedOnce) {
        await store.write(const FirstRunState(handlerArmedOnce: true));
      }
      final transport = FakeAgentTransport();
      final projectSession = ProjectSession(
        projectId: 'p',
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: await CachedSessionsStore.open(),
        onClose: () async => await transport.dispose(),
      );
      addTearDown(projectSession.close);

      final container = ProviderContainer(
        overrides: [
          firstRunStoreProvider.overrideWithValue(store),
          selectedRegistrationIdProvider.overrideWithValue('p'),
          projectSessionProvider('p').overrideWith((ref) => projectSession),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            home: const Scaffold(
              body: SizedBox.shrink(key: ValueKey('probe')),
            ),
          ),
        ),
      );
      await tester.pump();
      return (
        transport,
        container,
        tester.element(find.byKey(const ValueKey('probe'))),
      );
    }

    Map<String, dynamic> armFrame(FakeAgentTransport transport) =>
        transport.sent.firstWhere((m) => m['type'] == 'handler:configure');

    /// The bridge answering that the terminal is armed, which is what the flow
    /// waits on before retiring anything. Without it the confirmation window
    /// stays open and its timer outlives the test.
    Future<void> confirmArmed(
      WidgetTester tester,
      FakeAgentTransport transport,
    ) async {
      transport.emit('handler:status', {
        'projectId': 'p',
        'sessions': [
          {
            'terminalId': 't1',
            'notifyOnly': false,
            'state': 'watching',
            'pendingEscalations': 0,
            'armedAt': 1,
            'goal': 'fix the flaky login test',
            'backlog': <dynamic>[],
          },
        ],
      });
      await tester.pumpAndSettle();
    }

    testWidgets('a remembered prompt arms as the session goal', (tester) async {
      final (transport, container, context) = await pumpArm(
        tester,
        armedOnce: true,
      );
      container
          .read(sessionOpeningPromptsProvider.notifier)
          .remember('t1', 'fix the flaky login test');

      await armWithFirstRunExplainer(
        context: context,
        container: container,
        terminalId: 't1',
        notifyOnly: false,
        agentObservable: true,
      );

      final sent = armFrame(transport);
      expect(sent['armed'], true);
      expect(sent['goal'], 'fix the flaky login test');
      // The backlog stays the bridge's — the goal is what it extracts one from.
      expect(sent.containsKey('backlog'), isFalse);
      await confirmArmed(tester, transport);
    });

    testWidgets('a session nothing remembers still arms with no payload', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(
        tester,
        armedOnce: true,
      );

      await armWithFirstRunExplainer(
        context: context,
        container: container,
        terminalId: 't1',
        notifyOnly: false,
        agentObservable: true,
      );

      final sent = armFrame(transport);
      expect(sent['armed'], true);
      expect(sent.containsKey('goal'), isFalse);
      expect(sent.containsKey('backlog'), isFalse);
      await confirmArmed(tester, transport);
    });

    testWidgets('the prompt is dropped once the bridge confirms the arm, so a '
        're-arm queues nothing twice', (tester) async {
      final (transport, container, context) = await pumpArm(
        tester,
        armedOnce: true,
      );
      container
          .read(sessionOpeningPromptsProvider.notifier)
          .remember('t1', 'revert the last migration');

      await armWithFirstRunExplainer(
        context: context,
        container: container,
        terminalId: 't1',
        notifyOnly: false,
        agentObservable: true,
      );
      await confirmArmed(tester, transport);
      expect(container.read(sessionOpeningPromptsProvider)['t1'], isNull);

      // A plain disarm leaves the bridge nothing to rehydrate, so a goal sent
      // again here is extracted into an empty backlog and done a second time.
      transport.clearSent();
      await armWithFirstRunExplainer(
        context: context,
        container: container,
        terminalId: 't1',
        notifyOnly: false,
        agentObservable: true,
      );
      expect(armFrame(transport).containsKey('goal'), isFalse);
      await confirmArmed(tester, transport);
    });

    testWidgets('the first arm tells the user the goal is being seeded', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(
        tester,
        armedOnce: false,
      );
      container
          .read(sessionOpeningPromptsProvider.notifier)
          .remember('t1', 'fix the flaky login test');

      unawaited(
        armWithFirstRunExplainer(
          context: context,
          container: container,
          terminalId: 't1',
          notifyOnly: false,
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'It starts from what you asked for when you opened this session',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
      await tester.pumpAndSettle();
      expect(armFrame(transport)['goal'], 'fix the flaky login test');
      await confirmArmed(tester, transport);
    });

    testWidgets('with nothing remembered the first arm promises no backlog', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(
        tester,
        armedOnce: false,
      );

      unawaited(
        armWithFirstRunExplainer(
          context: context,
          container: container,
          terminalId: 't1',
          notifyOnly: false,
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('It starts from what you asked for'),
        findsNothing,
      );
      await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
      await tester.pumpAndSettle();
      expect(armFrame(transport).containsKey('goal'), isFalse);
      await confirmArmed(tester, transport);
    });
  });

  group('HandlerHeaderControl shield form', () {
    List<Override> overrides(FirstRunStore store) => [
      firstRunStoreProvider.overrideWithValue(store),
      activeSessionIdProvider.overrideWith(
        () => ValueController<String?>('t1'),
      ),
      activeSessionProvider.overrideWith((_) => null),
      handlerStateProvider.overrideWith(
        (_) => Stream.value(const HandlerState.initial()),
      ),
    ];

    testWidgets('labeled Handler button before the first arm', (tester) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      await tester.pumpWidget(
        _wrap(const HandlerHeaderControl(), overrides: overrides(store)),
      );
      await tester.pump();
      expect(find.text('Handler'), findsOneWidget);
    });

    testWidgets('collapses to the bare shield once armed anywhere', (
      tester,
    ) async {
      useInMemoryPrefs();
      final store = await FirstRunStore.open();
      await store.write(const FirstRunState(handlerArmedOnce: true));
      await tester.pumpWidget(
        _wrap(const HandlerHeaderControl(), overrides: overrides(store)),
      );
      await tester.pump();
      expect(find.text('Handler'), findsNothing);
      expect(find.byTooltip('Arm Handler'), findsOneWidget);
    });
  });
}
