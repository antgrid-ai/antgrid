// The escalation card floated over the terminal. It answers for the FOCUSED
// session and nothing else, and its collapse flag has two reset rules — one per
// session, one per escalation — each of which looks unnecessary until the case
// the other does not cover.
import 'dart:async';

import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/handler/handler_decision_card.dart';
import 'package:antgrid/widgets/handler/handler_escalation_overlay.dart';
import 'package:antgrid/widgets/handler/handler_escalation_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

/// Identifies the terminal-shaped child the card floats over, so a tap can be
/// aimed at it by rect rather than at whichever Stack the Scaffold builds.
const _terminal = ValueKey('terminal');

HandlerSessionState _armed(
  String terminalId, {
  List<HandlerEscalation> escalations = const [],
}) => HandlerSessionState(
  terminalId: terminalId,
  runState: escalations.isEmpty
      ? HandlerRunState.watching
      : HandlerRunState.needsYou,
  pendingEscalations: escalations.length,
  armedAt: 1,
  goal: 'ship it',
  backlog: const [],
  escalations: escalations,
);

/// [withChoices] false is the plain free-text row; the choices arm is what puts
/// two labelled buttons on screen, which is how "expanded" is asserted without
/// reaching into the widget's own state.
HandlerEscalation _escalation(
  String id, {
  required String terminalId,
  required String question,
  String urgency = 'normal',
  int at = 1,
  bool withChoices = true,
}) => HandlerEscalation(
  escalationId: id,
  terminalId: terminalId,
  question: question,
  reasoning: 'because',
  draftReply: 'yes',
  urgency: urgency,
  at: at,
  choices: withChoices
      ? const [
          HandlerEscalationChoice(
            choiceId: 'approve',
            label: 'Approve',
            text: 'go ahead',
          ),
          HandlerEscalationChoice(
            choiceId: 'reject',
            label: 'Reject',
            text: 'stop',
          ),
        ]
      : null,
);

HandlerState _state({
  required Map<String, HandlerSessionState> sessions,
  required List<HandlerEscalation> escalations,
}) => const HandlerState.initial().copyWith(
  sessions: sessions,
  escalations: escalations,
);

/// The chevron carries no text, so the icon it draws is the only thing that
/// identifies it — the idiom `handler_pa_bar_test` uses for the brief marker.
Finder _chevron(String icon) =>
    find.byWidgetPredicate((w) => w is AbIcon && w.icon == icon);

/// Counts taps that reach the terminal underneath, so the hit-test invariant
/// (an [Align] rather than a fill-sized barrier) is asserted rather than
/// assumed — a dead terminal is otherwise invisible until a user reports it.
class _TapSpy {
  int count = 0;
}

/// Drives the handler stream directly so a test can retire one escalation and
/// stand up the next inside one mounted [HandlerEscalationOverlay] — which is
/// the only way to reach the per-escalation reset at all.
class _Harness {
  _Harness(this.container, this._states);
  final ProviderContainer container;
  final StreamController<HandlerState> _states;

  /// Publishes a state and pumps the TWO frames it takes to appear. The stream
  /// hands the event to the provider on a microtask, so the first frame is
  /// already built by the time the widget is marked dirty and only the second
  /// draws it — a single pump asserts against the previous escalation and reads
  /// as the reset having failed. [_pump] never needs this because it seeds the
  /// stream before `pumpWidget`, which is itself a frame.
  Future<void> emit(WidgetTester tester, HandlerState state) async {
    _states.add(state);
    await tester.pump();
    await tester.pump();
  }
  void focus(String terminalId) =>
      container.read(activeSessionIdProvider.notifier).set(terminalId);
}

/// Mounts the overlay in the Stack the agent panel gives it: a terminal-shaped
/// child underneath and the card floating over it, inside an [Expanded] so the
/// card is bounded exactly as it is in production.
Future<_Harness> _pump(
  WidgetTester tester, {
  required Map<String, HandlerSessionState> sessions,
  required List<HandlerEscalation> escalations,
  String activeId = 't1',
  _TapSpy? spy,
}) async {
  final states = StreamController<HandlerState>();
  addTearDown(states.close);
  states.add(_state(sessions: sessions, escalations: escalations));

  final container = ProviderContainer(
    overrides: [
      activeSessionIdProvider.overrideWith(() => ValueController(activeId)),
      handlerStateProvider.overrideWith((ref) => states.stream),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => spy?.count++,
                      child: const SizedBox.expand(key: _terminal),
                    ),
                    // Keyed by session exactly as `AgentPanel` mounts it, so
                    // the per-session half of the collapse reset is under test
                    // rather than assumed.
                    Consumer(
                      builder: (_, ref, _) => HandlerEscalationOverlay(
                        key: ValueKey(ref.watch(activeSessionIdProvider)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return _Harness(container, states);
}

const _approveText = 'yes, use bun for the new package';

/// A `handler:status` snapshot arming t1, which is what makes the escalation
/// below reach a session the service knows about.
Map<String, dynamic> _armedStatusJson() => {
  'projectId': 'p',
  'sessions': [
    {
      'terminalId': 't1',
      'state': 'watching',
      'pendingEscalations': 0,
      'armedAt': 1,
      'goal': 'ship it',
      'backlog': <Map<String, dynamic>>[],
      'escalations': <Map<String, dynamic>>[],
    },
  ],
};

/// The one-shot `handler:escalation` push, in the two shapes this surface has
/// to answer differently: with [choices] it is a one-tap card, and with
/// [kind] `resolve_in_session` it is the option-based prompt no injected text
/// can resolve.
Map<String, dynamic> _escalationJson({
  List<Map<String, dynamic>>? choices,
  String? kind,
}) => {
  'projectId': 'p',
  'escalationId': 'e1',
  'terminalId': 't1',
  'question': 'bun or vitest?',
  'reasoning': 'Affects CI wiring.',
  'draftReply': 'use bun',
  'urgency': 'high',
  'choices': ?choices,
  'kind': ?kind,
};

/// The plain-row arm of [HandlerEscalationRow], whose `onTap` is the whole
/// difference between an interactive row and an informational one (see
/// `AbListRow`'s own doc).
final Finder _row = find.descendant(
  of: find.byType(HandlerEscalationRow),
  matching: find.byType(AbListRow),
);

/// The advert crosses the transport, the router and the service before the
/// provider rebuilds the overlay — one frame short and the card is not there
/// yet.
Future<void> _pumpDelivery(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// Mounts the overlay over a REAL [HandlerService], in the Stack the agent
/// panel gives it.
///
/// The lighter [_pump] above overrides `handlerStateProvider` alone, which
/// leaves `serviceWhenReady` unresolved and every callback the card takes null
/// — so those cases assert pixels and nothing else. UX-5's whole claim is that
/// the question is answerable in place, over the terminal that stopped, and
/// only a live service can carry a tap as far as the wire.
Future<FakeAgentTransport> _pumpLive(WidgetTester tester) async {
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final projectSession = ProjectSession(
    projectId: 'p',
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
  final heavy = projectSession.heavyStream.listen((_) {}); // unpause the gate
  addTearDown(() async {
    await heavy.cancel();
    await projectSession.close();
  });

  final container = ProviderContainer(
    overrides: [
      // serviceWhenReady gates on a focused id AND a resolved session before it
      // reads the façade, so without both of these every callback is null and
      // the tap is a silent no-op.
      selectedRegistrationIdProvider.overrideWithValue('p'),
      projectSessionProvider.overrideWith((ref, id) async => projectSession),
      handlerServiceProvider.overrideWithValue(projectSession.handlerService),
      handlerStateProvider.overrideWith(
        (ref) => projectSession.handlerService.stateStream,
      ),
      activeSessionIdProvider.overrideWith(() => ValueController('t1')),
    ],
  );
  addTearDown(container.dispose);
  await container.read(projectSessionProvider('p').future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    SizedBox.expand(key: _terminal),
                    HandlerEscalationOverlay(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return transport;
}

void main() {
  testWidgets('nothing renders with no escalation on the focused session', (
    tester,
  ) async {
    await _pump(tester, sessions: {'t1': _armed('t1')}, escalations: const []);
    expect(find.byType(HandlerEscalationRow), findsNothing);
  });

  testWidgets("a background session's escalation never reaches the panel", (
    tester,
  ) async {
    // The single most important case here: the overlay reads
    // `focusedSessionHandlerStateProvider`, and reading the unnarrowed
    // `handlerStateProvider` instead — which the agent bar's NEEDS YOU pill
    // does deliberately, thirty lines away in the same file — would float
    // another session's question over this terminal, attributed to the agent on
    // screen.
    await _pump(
      tester,
      sessions: {'t1': _armed('t1'), 't2': _armed('t2')},
      escalations: [
        _escalation('e2', terminalId: 't2', question: 'delete the branch?'),
      ],
    );
    expect(find.text('delete the branch?'), findsNothing);
    expect(find.byType(HandlerEscalationRow), findsNothing);
  });

  testWidgets('the card arrives expanded', (tester) async {
    // A question that announces itself as one line the user has to open is a
    // question they will not read.
    await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
    );
    expect(find.byType(HandlerDecisionCard), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  testWidgets('the chevron collapses to one line and back', (tester) async {
    await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
    );

    await tester.tap(_chevron(AbIcons.chevronDown));
    await tester.pump();
    expect(find.text('Approve'), findsNothing);
    // The question survives the collapse — the strip has to say what is
    // waiting, or the terminal it uncovered is all the user has to go on.
    expect(find.text('proceed?'), findsOneWidget);

    await tester.tap(_chevron(AbIcons.chevronUp));
    await tester.pump();
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('a new question arrives expanded after the last was collapsed', (
    tester,
  ) async {
    // The reset the per-session key cannot cover: one card retires and the next
    // takes its slot inside the same State, inheriting a collapsed flag that
    // was never about it.
    final harness = await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
    );

    await tester.tap(_chevron(AbIcons.chevronDown));
    await tester.pump();
    expect(find.text('Approve'), findsNothing);

    await harness.emit(
      tester,
      _state(
        sessions: {'t1': _armed('t1')},
        escalations: [
          _escalation('e2', terminalId: 't1', question: 'force push?'),
        ],
      ),
    );

    expect(find.text('force push?'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('collapse does not survive a session switch', (tester) async {
    // The reset the escalationId guard cannot cover, and the reason the panel
    // keys this widget by session.
    final harness = await _pump(
      tester,
      sessions: {'t1': _armed('t1'), 't2': _armed('t2')},
      // Both rows carry the SAME escalationId on purpose: the per-escalation
      // guard cannot fire, so only the key rebuilding the State can keep the
      // new session's card open.
      escalations: [
        _escalation('e1', terminalId: 't1', question: 'proceed?'),
        _escalation('e1', terminalId: 't2', question: 'force push?'),
      ],
    );

    await tester.tap(_chevron(AbIcons.chevronDown));
    await tester.pump();
    expect(find.text('Approve'), findsNothing);

    harness.focus('t2');
    await tester.pump();

    expect(find.text('force push?'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('the overlay does not swallow taps outside its own bounds', (
    tester,
  ) async {
    // An `Align` hit-tests only its child. A `GestureDetector` with an opaque
    // behaviour around the card, or a ColoredBox on the Positioned.fill, would
    // make the whole terminal stop taking clicks and text selection — with no
    // error and no visual change.
    final spy = _TapSpy();
    await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
      spy: spy,
    );

    final terminal = tester.getRect(find.byKey(_terminal));
    await tester.tapAt(Offset(terminal.center.dx, terminal.top + 8));
    await tester.pump();

    expect(spy.count, 1);
  });

  testWidgets('the card takes the pointers that land on it', (tester) async {
    // The other half of the invariant above, and the one that is invisible:
    // the card PAINTS over the terminal without covering it, so a tap on the
    // header band beside the chevron reaches `TerminalScreen` — which, with
    // mouse reporting on, forwards a click at that cell into the agent's own
    // TUI. Aimed at the band's left edge on purpose: that is the reach that
    // misses the chevron, and the [Align] holding the cluster hit-tests only
    // its child.
    final spy = _TapSpy();
    await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
      spy: spy,
    );

    final terminal = tester.getRect(find.byKey(_terminal));
    final band = tester.getRect(_chevron(AbIcons.chevronDown));
    await tester.tapAt(Offset(terminal.left + 8, band.center.dy));
    await tester.pump();

    expect(spy.count, 0);
    // Absorbed, not acted on: an errant tap must not collapse the question
    // that stopped the session.
    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('the collapsed strip expands from anywhere in the band', (
    tester,
  ) async {
    // On a phone the chevron is a 24px glyph in the bottom-right corner,
    // directly above the PA bar's own controls, and it is the only route back
    // to a question the user cannot read. The band carries the toggle so a
    // thumb that misses low still opens the card instead of answering the bar.
    final spy = _TapSpy();
    await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
      spy: spy,
    );

    await tester.tap(_chevron(AbIcons.chevronDown));
    await tester.pump();
    expect(find.text('Approve'), findsNothing);

    final terminal = tester.getRect(find.byKey(_terminal));
    final band = tester.getRect(_chevron(AbIcons.chevronUp));
    await tester.tapAt(Offset(terminal.left + 8, band.center.dy));
    await tester.pump();

    expect(find.text('Approve'), findsOneWidget);
    expect(spy.count, 0);
  });

  testWidgets('a dropped question that comes back arrives expanded', (
    tester,
  ) async {
    // `HandlerService._dropRows` retires an answered row optimistically and the
    // next `handler:status` reconciles authoritatively — so the SAME
    // escalationId returns whenever the reply did not retire the row on the
    // bridge. Neither reset covers that on its own: the session never changed,
    // so the key holds, and the id never changed, so the guard sees nothing —
    // unless the empty frame released the slot.
    final harness = await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [_escalation('e1', terminalId: 't1', question: 'proceed?')],
    );

    await tester.tap(_chevron(AbIcons.chevronDown));
    await tester.pump();
    expect(find.text('Approve'), findsNothing);

    await harness.emit(
      tester,
      _state(sessions: {'t1': _armed('t1')}, escalations: const []),
    );
    expect(find.byType(HandlerEscalationRow), findsNothing);

    await harness.emit(
      tester,
      _state(
        sessions: {'t1': _armed('t1')},
        escalations: [
          _escalation('e1', terminalId: 't1', question: 'proceed?'),
        ],
      ),
    );

    expect(find.text('Approve'), findsOneWidget);
  });

  testWidgets('the head of the banded list is the one shown', (tester) async {
    // `compareEscalations` bands urgent first and `HandlerService` sorts on
    // both fill paths, so the head is the row holding the session up. A switch
    // to `.last` here — "show the newest" — would float a stale normal-urgency
    // question over a session stopped on something else.
    await _pump(
      tester,
      sessions: {'t1': _armed('t1')},
      escalations: [
        _escalation(
          'e2',
          terminalId: 't1',
          question: 'force push?',
          urgency: 'high',
          at: 2,
          withChoices: false,
        ),
        _escalation(
          'e1',
          terminalId: 't1',
          question: 'rename the file?',
          at: 1,
          withChoices: false,
        ),
      ],
    );

    expect(find.text('force push?'), findsOneWidget);
    expect(find.text('rename the file?'), findsNothing);
    expect(find.text('URGENT'), findsOneWidget);
  });

  testWidgets('a one-tap over the terminal reaches the wire', (tester) async {
    // The reason this surface exists: answering in place, over the session that
    // stopped. Asserted as a frame rather than as pixels, because a wrong
    // callback, a `focusedServiceOrNull` that resolves the wrong project, or an
    // `onChoice` returning false all render identically and all leave the user
    // tapping Approve at a stopped terminal for nothing.
    final t = await _pumpLive(tester);
    t.emit('handler:status', _armedStatusJson());
    await _pumpDelivery(tester);
    t.emit(
      'handler:escalation',
      _escalationJson(
        choices: [
          {'choiceId': 'approve', 'label': 'Approve', 'text': _approveText},
          {'choiceId': 'reject', 'label': 'Reject', 'text': 'no, keep vitest'},
        ],
      ),
    );
    await _pumpDelivery(tester);

    expect(find.text('Approve'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await _pumpDelivery(tester);

    final sent = t.sent.where((m) => m['type'] == 'terminal:input').toList();
    expect(sent, hasLength(1));
    expect(sent.single['terminalId'], 't1');
    expect(sent.single['data'], '$_approveText\r');
    // The answered row leaves with its card.
    expect(find.text('Approve'), findsNothing);
  });

  testWidgets('a free-text row over the terminal offers its reply', (
    tester,
  ) async {
    // The control for the case below: with the service resolved, a row this
    // surface CAN answer is interactive, so a null `onTap` there is a decision
    // rather than an unresolved harness.
    final t = await _pumpLive(tester);
    t.emit('handler:status', _armedStatusJson());
    await _pumpDelivery(tester);
    t.emit('handler:escalation', _escalationJson());
    await _pumpDelivery(tester);

    expect(tester.widget<AbListRow>(_row).onTap, isNotNull);
  });

  testWidgets('an in-session prompt is informational, not a dead tap', (
    tester,
  ) async {
    // A PTY AskUserQuestion mints `resolve_in_session` (the forced blocking
    // prompt escalate in handler/engine.ts), and this overlay is floating over
    // the very terminal drawing that prompt — so the branch
    // `answerHandlerEscalation` would take is a focus change onto the session
    // already in focus. `AbListRow` renders a null `onTap` as an informational
    // row; a non-null one would give the question hover and press feedback for
    // a tap that answers nothing.
    final t = await _pumpLive(tester);
    t.emit('handler:status', _armedStatusJson());
    await _pumpDelivery(tester);
    t.emit('handler:escalation', _escalationJson(kind: 'resolve_in_session'));
    await _pumpDelivery(tester);

    expect(find.text('bun or vitest?'), findsOneWidget);
    expect(tester.widget<AbListRow>(_row).onTap, isNull);
  });
}
