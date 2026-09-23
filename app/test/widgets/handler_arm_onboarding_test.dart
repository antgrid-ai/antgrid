import 'dart:async';

import 'package:antgrid/billing/pricing_visibility.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/navigation/root_navigator.dart';
import 'package:antgrid/providers/agent_catalog.dart';
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
import 'package:antgrid/widgets/handler/handler_judge_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// The bridge is authoritative for what an agent is called and what it can do,
/// so a judge picker has nothing to list until an advert has landed.
class _SeededCatalog extends AgentCatalogNotifier {
  _SeededCatalog(this.seed);

  final Map<String, AgentDescriptor> seed;

  @override
  Map<String, AgentDescriptor> build() => seed;
}

AgentDescriptor _descriptor(String tool) => AgentDescriptor(
  tool: tool,
  label: tool[0].toUpperCase() + tool.substring(1),
  chatCapable: true,
  judgeCapable: true,
  handlerTerminal: true,
  handlerChat: true,
);

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

    test('the seeded goal is not described here at all', () {
      // It used to be, as a paragraph saying a backlog would appear from
      // something typed on another screen. The sheet now shows that sentence
      // itself, directly above the composer asking what to add beyond it, so
      // the paragraph had become the same fact stated twice in a row.
      expect(handlerArmExplainerBody(agentObservable: true), base);
      expect(
        handlerArmExplainerBody(agentObservable: true),
        isNot(contains('starts from what you asked for')),
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
      );
      expect(body, endsWith(unwatchableNotice('Claude Code')));
    });

    group('past the first arm', () {
      test('a covered agent with nothing to add says nothing at all', () {
        // The sheet opens on every arm, so the standing explanation would
        // otherwise be re-read by a user who has armed a hundred sessions.
        expect(
          handlerArmExplainerBody(agentObservable: true, explain: false),
          isNull,
        );
      });

      test('the standing explanation is the only thing dropped', () {
        // Coverage is per-agent: it is not retired by having read the
        // explanation once.
        expect(
          handlerArmExplainerBody(
            agentObservable: false,
            agentLabel: 'Claude Code',
            explain: false,
          ),
          unwatchableNotice('Claude Code'),
        );
        expect(
          handlerArmExplainerBody(
            agentObservable: true,
            judgeCapable: false,
            explain: false,
          ),
          escalateOnlyNotice,
        );
        expect(
          handlerArmExplainerBody(agentObservable: null, explain: false),
          "This agent hasn't reported what Handler can see here, so it may "
          'stay silent.',
        );
      });

      test('a seeded goal adds nothing back to this copy', () {
        // The goal is shown on the sheet as itself, so a repeat arm over a
        // covered agent still says nothing here — goal or no goal.
        expect(
          handlerArmExplainerBody(agentObservable: true, explain: false),
          isNull,
        );
      });
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

    test('a refused machine outranks every coverage answer', () {
      // Coverage describes what an arm WOULD get, and there is no arm to get
      // it — so a fully covered agent on a refused machine still says why.
      expect(
        handlerShieldTooltip(
          armed: false,
          observable: true,
          judgeCapable: true,
          entitlement: const HandlerEntitlement(
            reason: HandlerEntitlementReason.notEntitled,
            tier: 'free',
          ),
        ),
        kPricingSurfacesEnabled
            ? contains('Free plan')
            : contains("isn't available"),
      );
      expect(
        handlerShieldTooltip(
          armed: false,
          observable: false,
          judgeCapable: false,
          agentLabel: 'Claude Code',
          entitlement: const HandlerEntitlement(
            reason: HandlerEntitlementReason.unreadable,
          ),
        ),
        handlerEntitlementNotice(
          const HandlerEntitlement(reason: HandlerEntitlementReason.unreadable),
        ),
      );
    });

    test("a session armed before the refusal is still the user's to disarm", () {
      expect(
        handlerShieldTooltip(
          armed: true,
          observable: true,
          judgeCapable: true,
          entitlement: const HandlerEntitlement(
            reason: HandlerEntitlementReason.notEntitled,
            tier: 'free',
          ),
        ),
        'Disarm Handler',
      );
    });
  });

  group('handlerEntitlementNotice', () {
    test('names no plan while pricing is hidden', () {
      final notice = handlerEntitlementNotice(
        const HandlerEntitlement(
          reason: HandlerEntitlementReason.notEntitled,
          tier: 'free',
        ),
      );
      expect(notice, isNot(contains('Pro')));
      expect(notice, isNot(contains('plan')));
    }, skip: kPricingSurfacesEnabled);

    test('names the plan the machine is on when the bridge could read one', skip: !kPricingSurfacesEnabled, () {
      // "You need Pro" alone leaves a paying user unable to tell whether they
      // already have it.
      expect(
        handlerEntitlementNotice(
          const HandlerEntitlement(
            reason: HandlerEntitlementReason.notEntitled,
            tier: 'free',
          ),
        ),
        contains('Free plan'),
      );
    });

    test('an unreadable claim is sent to sign-in, never to checkout', () {
      final notice = handlerEntitlementNotice(
        const HandlerEntitlement(reason: HandlerEntitlementReason.unreadable),
      );
      expect(notice, contains('Sign out and back in'));
      expect(notice, isNot(contains('Pro')));
    });

    test('a reason this app cannot name still says arming will not work', () {
      // Silence is the failure being fixed, so an unknown reason falls back to
      // unavailability rather than to nothing.
      expect(
        handlerEntitlementNotice(const HandlerEntitlement()),
        contains("isn't available"),
      );
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

  group('armWithSheet carries the opening prompt', () {
    /// A REAL [ProjectSession] over a fake transport, focused: the goal is only
    /// proven seeded if the arm the flow sends carries it on the wire, and the
    /// flow resolves its service off the focused project rather than off
    /// anything the caller hands it.
    Future<(FakeAgentTransport, ProviderContainer, BuildContext)> pumpArm(
      WidgetTester tester, {
      bool armedOnce = false,
      List<Override> extraOverrides = const [],
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
          ...extraOverrides,
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            // The flow's own failure reports go to the ROOT navigator's
            // overlay, since every widget that could have shown one is gone by
            // then — so the key has to be the one the provider hands out.
            navigatorKey: container.read(rootNavigatorKeyProvider),
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

    /// A toast dismisses itself on a timer, and a timer outliving the tree
    /// fails the test — so every assertion on one has to let it finish.
    Future<void> settleToast(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    }

    Map<String, dynamic> armFrame(FakeAgentTransport transport) =>
        transport.sent.firstWhere((m) => m['type'] == 'handler:configure');

    /// The whole flow as a user performs it: the sheet is not skippable, so
    /// every arm here goes through it and commits on its own button.
    Future<void> armThroughSheet(
      WidgetTester tester,
      ProviderContainer container,
      BuildContext context,
    ) async {
      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
      await tester.pumpAndSettle();
    }

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

    /// The machine naming the lenses it reads. Presence of the list is the
    /// capability signal, so a sheet opened before one lands offers nothing to
    /// pick — every test that touches the lens row sends this first.
    Future<void> advertiseLenses(
      WidgetTester tester,
      FakeAgentTransport transport,
    ) async {
      transport.emit('handler:status', {
        'projectId': 'p',
        'sessions': <dynamic>[],
        'lenses': ['pm', 'qa', 'critic', 'release'],
      });
      await tester.pumpAndSettle();
    }

    testWidgets('a remembered prompt arms as the session goal', (tester) async {
      final (transport, container, context) = await pumpArm(tester);
      container
          .read(sessionOpeningPromptsProvider.notifier)
          .remember('t1', 'fix the flaky login test');

      await armThroughSheet(tester, container, context);

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
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      await armThroughSheet(tester, container, context);

      final sent = armFrame(transport);
      expect(sent['armed'], true);
      expect(sent.containsKey('goal'), isFalse);
      expect(sent.containsKey('backlog'), isFalse);
      // A cold cache over a session the bridge holds a lens for is the ordinary
      // case after a restart, so an untouched control must send nothing rather
      // than reset that pick to the default.
      expect(sent.containsKey('role'), isFalse);
      expect(sent.containsKey('brief'), isFalse);
      await confirmArmed(tester, transport);
    });

    testWidgets('the sheet opens on every arm, not just the first', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(
        tester,
        armedOnce: true,
      );

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Arm Handler'), findsWidgets);
      // …but without re-teaching what Handler is. The composer and the lens
      // control are the whole sheet from here on.
      expect(
        find.textContaining('Handler watches this session while'),
        findsNothing,
      );
      // Nothing is armed until the sheet's own commit — the tap that opened it
      // is not the arm.
      expect(
        transport.sent.where((m) => m['type'] == 'handler:configure'),
        isEmpty,
      );

      await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
      await tester.pumpAndSettle();
      expect(armFrame(transport)['armed'], true);
      await confirmArmed(tester, transport);
    });

    testWidgets('a lens picked on the sheet rides the arm', (tester) async {
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proof it works'));
      await tester.pumpAndSettle();
      final armButton = find.widgetWithText(AbButton, 'Arm Handler');
      await tester.ensureVisible(armButton);
      await tester.pumpAndSettle();
      await tester.tap(armButton);
      await tester.pumpAndSettle();

      expect(armFrame(transport)['role'], 'qa');
      // A preset is exclusive with the user's own stance (redesign spec §6), so
      // it clears the brief explicitly rather than omitting it — an omitted
      // field means "leave the stored one alone", which would run this preset
      // on top of a user lens the sheet no longer shows.
      expect(armFrame(transport)['brief'], '');
      await confirmArmed(tester, transport);
    });

    testWidgets('the last lens tapped is the one that rides the arm', (
      tester,
    ) async {
      // The row is a radio and the arm collects rather than commits, so only
      // the final pick may reach the wire — an earlier one arriving instead
      // would arm the session under a lens the user moved off.
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('What could break'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Stays in scope'));
      await tester.pumpAndSettle();
      final armButton = find.widgetWithText(AbButton, 'Arm Handler');
      await tester.ensureVisible(armButton);
      await tester.pumpAndSettle();
      await tester.tap(armButton);
      await tester.pumpAndSettle();

      expect(armFrame(transport)['role'], 'pm');
      await confirmArmed(tester, transport);
    });

    testWidgets('the arm sheet offers no chip for adding nothing', (
      tester,
    ) async {
      // A session with no lens is still judged — the floor line above the row
      // says so — so a chip for it asked the user to choose the state they are
      // already in.
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Nothing extra'), findsNothing);
      for (final label in const [
        'Stays in scope',
        'Proof it works',
        'What could break',
        'Ready to ship',
        'Your own',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    });

    testWidgets('the arm sheet opens with the cursor in the instruction box', (
      tester,
    ) async {
      // The sheet exists to be answered with a sentence; making the user aim
      // at the box first is a step between them and the only act on it.
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .focusNode
            .hasFocus,
        isTrue,
      );
    });

    testWidgets('a multi-line draft survives the sheet echoing it back', (
      tester,
    ) async {
      // Under commitBriefOnEdit the sheet re-renders this control from the
      // JOINED brief on every keystroke. The panel must not read that echo of
      // the user's own typing as the bridge correcting it: writing it back
      // replaces their line breaks with "; " under the cursor, one keystroke
      // behind, and one rule per line is the whole shape the panel teaches
      // (redesign spec §7, §8).
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Your own'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('handlerOwnLensField')),
        'not done until the tests pass\nask before the payment path',
      );
      await tester.pumpAndSettle();

      final draft = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('handlerOwnLensField')),
          matching: find.byType(EditableText),
        ),
      );
      expect(
        draft.controller.text,
        'not done until the tests pass\nask before the payment path',
      );

      final armButton = find.widgetWithText(AbButton, 'Arm Handler');
      await tester.ensureVisible(armButton);
      await tester.pumpAndSettle();
      await tester.tap(armButton);
      await tester.pumpAndSettle();

      // The wire still gets the one line the bridge will store, each rule kept
      // bounded through `oneLine`'s newline-to-space collapse (§8).
      expect(
        armFrame(transport)['brief'],
        'not done until the tests pass; ask before the payment path',
      );
      await confirmArmed(tester, transport);
    });

    testWidgets('a brief typed and never submitted rides the arm alone', (
      tester,
    ) async {
      // The sheet's one commit is its button, so a field waiting on Enter would
      // drop what the user wrote — and a brief must not carry a lens clear the
      // user never made.
      final (transport, container, context) = await pumpArm(tester);
      await advertiseLenses(tester, transport);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();
      // "Your own" reveals the panel — the free-text field is no longer always
      // on screen (redesign spec §3, §6).
      await tester.tap(find.text('Your own'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(AbTextField),
        '  watch the migrations  ',
      );
      await tester.pumpAndSettle();
      // The panel's minimum three lines push the button past the fold that
      // fit it before the redesign, so it needs a scroll into view rather
      // than a bare tap.
      final armButton = find.widgetWithText(AbButton, 'Arm Handler');
      await tester.ensureVisible(armButton);
      await tester.pumpAndSettle();
      await tester.tap(armButton);
      await tester.pumpAndSettle();

      expect(armFrame(transport)['brief'], 'watch the migrations');
      // "Your own" is a tap on the same radio the four presets sit in
      // (redesign spec §3.2, §9), so it touches the role same as they do —
      // clearing it explicitly (`''`) rather than omitting it is what keeps a
      // role this arm never asked for from riding along from a stale seed.
      expect(armFrame(transport)['role'], '');
      await confirmArmed(tester, transport);
    });

    /// The bridge saying this machine will not run Handler at all. Emitted with
    /// no armed sessions, which is the state a refusal always leaves behind.
    Future<void> refuse(
      WidgetTester tester,
      FakeAgentTransport transport,
      Map<String, dynamic> entitlement,
    ) async {
      transport.emit('handler:status', {
        'projectId': 'p',
        'sessions': <dynamic>[],
        'entitlement': entitlement,
      });
      await tester.pumpAndSettle();
    }

    testWidgets('a paywalled machine explains itself instead of arming', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(tester);
      await refuse(tester, transport, {'reason': 'not_entitled', 'tier': 'free'});

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      // The arm sheet is a form that could not have committed, so it never
      // opens: the refusal takes its place and offers the one fix it has.
      if (kPricingSurfacesEnabled) {
        expect(find.text('Handler needs Pro'), findsOneWidget);
        expect(find.textContaining('Free plan'), findsOneWidget);
        expect(find.widgetWithText(AbButton, 'See plans'), findsOneWidget);
      } else {
        expect(find.text('Handler is unavailable'), findsOneWidget);
        expect(find.textContaining('Pro'), findsNothing);
        expect(find.widgetWithText(AbButton, 'See plans'), findsNothing);
      }
      expect(find.widgetWithText(AbButton, 'Arm Handler'), findsNothing);

      await tester.tap(
        find.widgetWithText(
          AbButton,
          kPricingSurfacesEnabled ? 'Not now' : 'Close',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        transport.sent.where((m) => m['type'] == 'handler:configure'),
        isEmpty,
      );
    });

    testWidgets('an unreadable claim is never sold an upgrade', (tester) async {
      final (transport, container, context) = await pumpArm(tester);
      await refuse(tester, transport, {'reason': 'unreadable'});

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      // A purchase buys nothing here, and a button offering one would teach the
      // user the wrong thing about what went wrong.
      expect(find.text('Handler is unavailable'), findsOneWidget);
      expect(find.widgetWithText(AbButton, 'See plans'), findsNothing);
      expect(find.widgetWithText(AbButton, 'Close'), findsOneWidget);

      await tester.tap(find.widgetWithText(AbButton, 'Close'));
      await tester.pumpAndSettle();
      expect(
        transport.sent.where((m) => m['type'] == 'handler:configure'),
        isEmpty,
      );
    });

    testWidgets('a refusal the bridge stops sending stops gating the arm', (
      tester,
    ) async {
      // The gate is derived per frame on both ends: an app told once that
      // Handler is paywalled has no other way to learn that it no longer is.
      final (transport, container, context) = await pumpArm(tester);
      await refuse(tester, transport, {'reason': 'not_entitled', 'tier': 'free'});
      transport.emit('handler:status', {
        'projectId': 'p',
        'sessions': <dynamic>[],
      });
      await tester.pumpAndSettle();

      await armThroughSheet(tester, container, context);

      expect(armFrame(transport)['armed'], true);
      await confirmArmed(tester, transport);
    });

    testWidgets('a refusal arriving on the answer to an arm is spoken', (
      tester,
    ) async {
      // The stale-cache path: the app believed it was entitled, sent the arm,
      // and the bridge answered no. Without this the send is indistinguishable
      // from a tap that never registered until the confirmation window runs out
      // — and, with no instruction riding on it, not even then.
      final (transport, container, context) = await pumpArm(tester);

      await armThroughSheet(tester, container, context);
      expect(armFrame(transport)['armed'], true);

      await refuse(tester, transport, {'reason': 'not_entitled', 'tier': 'free'});

      expect(find.text('Handler not armed'), findsOneWidget);
      expect(
        find.textContaining(
          kPricingSurfacesEnabled ? 'Free plan' : "isn't available",
        ),
        findsOneWidget,
      );
      await settleToast(tester);
    });

    testWidgets('backing out of the sheet arms nothing', (tester) async {
      final (transport, container, context) = await pumpArm(tester);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(AbButton, 'Not now'));
      await tester.pumpAndSettle();

      expect(
        transport.sent.where((m) => m['type'] == 'handler:configure'),
        isEmpty,
      );
    });

    testWidgets('the prompt is dropped once the bridge confirms the arm, so a '
        're-arm queues nothing twice', (tester) async {
      final (transport, container, context) = await pumpArm(tester);
      container
          .read(sessionOpeningPromptsProvider.notifier)
          .remember('t1', 'revert the last migration');

      await armThroughSheet(tester, container, context);
      await confirmArmed(tester, transport);
      expect(container.read(sessionOpeningPromptsProvider)['t1'], isNull);

      // A plain disarm leaves the bridge nothing to rehydrate, so a goal sent
      // again here is extracted into an empty backlog and done a second time.
      transport.clearSent();
      await armThroughSheet(tester, container, context);
      expect(armFrame(transport).containsKey('goal'), isFalse);
      await confirmArmed(tester, transport);
    });

    testWidgets('an arm over a remembered prompt shows the goal it seeds', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(tester);
      container
          .read(sessionOpeningPromptsProvider.notifier)
          .remember('t1', 'fix the flaky login test');

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      // The sentence itself, verbatim — the sheet no longer describes it as
      // something typed elsewhere, it shows it.
      expect(
        find.text('Your backlog starts with: fix the flaky login test'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
      await tester.pumpAndSettle();
      expect(armFrame(transport)['goal'], 'fix the flaky login test');
      await confirmArmed(tester, transport);
    });

    testWidgets('with nothing remembered the sheet promises no backlog', (
      tester,
    ) async {
      final (transport, container, context) = await pumpArm(tester);

      unawaited(
        armWithSheet(
          context: context,
          container: container,
          terminalId: 't1',
          agentObservable: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Your backlog starts with'), findsNothing);
      // A first arm still gets the standing explanation — the other half of
      // what handlerArmedOnce gates on this sheet.
      expect(
        find.textContaining('Handler watches this session while'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
      await tester.pumpAndSettle();
      expect(armFrame(transport).containsKey('goal'), isFalse);
      await confirmArmed(tester, transport);
    });

    // The sharp edge of the whole feature: `handler:instruct` is DROPPED by the
    // bridge when no armed session exists, and the drop is a log line no phone
    // reads. So the sentence typed on this sheet cannot ride the arm, and
    // cannot be smuggled in as the goal either — a goal grants nothing, and
    // `instruct` is the one feed point for instruction-scoped authorization.
    group('the arm sheet composer', () {
      final field = find.byKey(const Key('handler-instruction-field'));

      List<Map<String, dynamic>> instructs(FakeAgentTransport transport) =>
          transport.sent
              .where((m) => m['type'] == 'handler:instruct')
              .toList();

      /// Opens the arm sheet and leaves it on screen.
      Future<void> openSheet(
        WidgetTester tester,
        ProviderContainer container,
        BuildContext context,
      ) async {
        unawaited(
          armWithSheet(
            context: context,
            container: container,
            terminalId: 't1',
            agentObservable: true,
          ),
        );
        await tester.pumpAndSettle();
      }

      testWidgets('typed text is not on the wire before the arm is confirmed', (
        tester,
      ) async {
        final (transport, container, context) = await pumpArm(tester);
        await openSheet(tester, container, context);

        await tester.enterText(field, 'also update the changelog');
        await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
        await tester.pumpAndSettle();

        // The arm went; the instruction did not go with it.
        expect(armFrame(transport)['armed'], true);
        expect(instructs(transport), isEmpty);

        await confirmArmed(tester, transport);
      });

      testWidgets('and lands exactly once when the bridge confirms', (
        tester,
      ) async {
        final (transport, container, context) = await pumpArm(tester);
        await openSheet(tester, container, context);

        await tester.enterText(field, 'also update the changelog');
        await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
        await tester.pumpAndSettle();
        await confirmArmed(tester, transport);

        expect(instructs(transport), hasLength(1));
        expect(instructs(transport).single['terminalId'], 't1');
        expect(instructs(transport).single['text'], 'also update the changelog');
      });

      testWidgets('an untouched composer sends no instruction at all', (
        tester,
      ) async {
        final (transport, container, context) = await pumpArm(tester);
        await openSheet(tester, container, context);

        // Arming with nothing typed is the ordinary case, and an empty
        // `handler:instruct` would spend an extraction pass on nothing.
        await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
        await tester.pumpAndSettle();
        await confirmArmed(tester, transport);

        expect(instructs(transport), isEmpty);
      });

      testWidgets('an arm the bridge never confirms sends nothing', (
        tester,
      ) async {
        // A send that vanished with nothing coming back to explain it: the
        // window closing is the end of it, not a late retry. The user is told,
        // because the sentence they typed exists nowhere else once it shuts.
        final (transport, container, context) = await pumpArm(tester);
        await openSheet(tester, container, context);

        await tester.enterText(field, 'also update the changelog');
        await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
        await tester.pumpAndSettle();
        await tester.pump(kHandlerArmConfirmWindow + const Duration(seconds: 1));
        await tester.pumpAndSettle();

        expect(instructs(transport), isEmpty);
        expect(find.text('Nothing was queued'), findsOneWidget);
        await settleToast(tester);
      });

      testWidgets('a judge picked here rides the arm, not a frame of its own', (
        tester,
      ) async {
        final (transport, container, context) = await pumpArm(
          tester,
          extraOverrides: [
            agentCatalogProvider.overrideWith(
              () => _SeededCatalog({
                'claude': _descriptor('claude'),
                'codex': _descriptor('codex'),
              }),
            ),
          ],
        );
        await openSheet(tester, container, context);

        await tester.tap(find.byType(HandlerJudgeChip));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Codex'));
        await tester.pumpAndSettle();
        // The panel stays open on a judge pick — the model is the next thing
        // the user may want — so it has to be dismissed before the sheet's own
        // commit is reachable.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        await tester.tap(find.widgetWithText(AbButton, 'Arm Handler'));
        await tester.pumpAndSettle();

        final configures = transport.sent
            .where((m) => m['type'] == 'handler:configure')
            .toList();
        expect(configures, hasLength(1));
        expect(configures.single['judgeTool'], 'codex');

        await confirmArmed(tester, transport);
      });
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
