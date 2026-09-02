// The pinned PA bar. It is one status row and nothing else: the instruction
// composer moved into the backlog drawer, because a second field with its own
// send button, pinned under the session composer, read as a rival place to type
// with nothing on either saying who receives it.
import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/widgets/handler/handler_backlog_drawer.dart';
import 'package:antgrid/widgets/handler/handler_instruction_composer.dart';
import 'package:antgrid/widgets/handler/handler_pa_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

/// [pendingEscalations] defaults to the length of [escalations] because the
/// bridge derives it from that same list — a session carrying a count with no
/// rows behind it never reaches the app, and the hint reads both.
HandlerSessionState _armed({
  HandlerRunState runState = HandlerRunState.watching,
  List<HandlerInstructionItem> backlog = const [],
  List<HandlerEscalation> escalations = const [],
  int? pendingEscalations,
  String? parkKind,
  int? parkedUntil,
  HandlerPersonality? personality,
  HandlerObservability? observability,
}) => HandlerSessionState(
  terminalId: 't1',
  runState: runState,
  pendingEscalations: pendingEscalations ?? escalations.length,
  armedAt: 1,
  goal: 'ship it',
  backlog: backlog,
  escalations: escalations,
  parkKind: parkKind,
  parkedUntil: parkedUntil,
  personality: personality,
  observability: observability,
);

/// The chip's colour is the whole assertion, and the harness below mounts no
/// palette extension — so read the one the bar itself resolved rather than
/// guessing which fallback is in force.
AbChip _chip(WidgetTester tester, String label) =>
    tester.widget<AbChip>(find.widgetWithText(AbChip, label));

HandlerInstructionItem _item(String id, String text, String status) =>
    HandlerInstructionItem(id: id, text: text, status: status, createdAt: 1);

/// [kind] null is the free-text row; 'resolve_in_session' is the option-based
/// prompt only the transcript can resolve; 'guard_blocked' is the report of an
/// action Handler could not take, which only its card's Dismiss retires.
HandlerEscalation _escalation(String id, {String? kind}) => HandlerEscalation(
  escalationId: id,
  terminalId: 't1',
  question: 'proceed?',
  reasoning: 'because',
  draftReply: 'yes',
  urgency: 'normal',
  at: 1,
  kind: kind,
);

List<HandlerEscalation> _replies(int n) => [
  for (var i = 0; i < n; i++) _escalation('e$i'),
];

/// The bar sends nothing of its own now, so this needs no project session — only
/// the focused terminal and the handler snapshot the row reads.
///
/// The first-run store is here for the drawer the row opens, not for the bar:
/// the drawer's disclaimer is retired by a persisted flag, and the provider
/// holding it throws unless the store is injected.
Future<void> _pump(
  WidgetTester tester, {
  required Map<String, HandlerSessionState> sessions,
  HandlerBacklogOpener? opener,
}) async {
  useInMemoryPrefs();
  final firstRun = await FirstRunStore.open();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        firstRunStoreProvider.overrideWithValue(firstRun),
        activeSessionIdProvider.overrideWith(() => ValueController('t1')),
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(
            const HandlerState.initial().copyWith(sessions: sessions),
          ),
        ),
        if (opener != null)
          handlerBacklogOpenerProvider.overrideWith(
            () => ValueController(opener),
          ),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SizedBox.shrink()),
              HandlerPaBar(),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the bar names the posture even when nobody has picked one', (
    tester,
  ) async {
    // The bar is on screen for the whole time a session is armed and is the
    // only place the posture is visible at all, so "no chip" would be a state
    // the user has to be taught to read.
    await _pump(tester, sessions: {'t1': _armed()});
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    expect(_chip(tester, 'WATCHDOG').color, p.textMuted);
  });

  testWidgets('the posture chip is tinted where nothing is being judged', (
    tester,
  ) async {
    // Escalate-only means no decide pass runs at all, so a bar naming a
    // posture in ordinary chrome would say the opposite of what is happening.
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          personality: HandlerPersonality.closer,
          observability: HandlerObservability.escalateOnly,
        ),
      },
    );
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    expect(_chip(tester, 'CLOSER').color, p.warning);
  });

  testWidgets('tapping the posture chip does not open the backlog', (
    tester,
  ) async {
    String? opened;
    await _pump(
      tester,
      sessions: {'t1': _armed()},
      opener: (terminalId) => opened = terminalId,
    );
    await tester.tap(find.text('WATCHDOG'));
    await tester.pump();
    expect(opened, isNull);
  });

  testWidgets('the bar offers no place to type of its own', (tester) async {
    // The whole point of the collapse: the session composer above it is the
    // one field, and Handler's own box lives a tap away in the drawer.
    await _pump(tester, sessions: {'t1': _armed()});
    expect(find.byType(AbTextField), findsNothing);
    expect(find.byType(HandlerInstructionComposer), findsNothing);
    expect(find.text(handlerDisclaimerText), findsNothing);
  });

  testWidgets('nothing renders without an armed session', (tester) async {
    await _pump(tester, sessions: const {});
    expect(find.text('Nothing queued'), findsNothing);
  });

  testWidgets('the status row reports the active item and its ordinal', (
    tester,
  ) async {
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          backlog: [
            _item('i1', 'fix the flake', 'done'),
            _item('i2', 'run integration tests', 'active'),
            _item('i3', 'open a PR', 'queued'),
            _item('i4', 'post the summary', 'queued'),
          ],
        ),
      },
    );
    expect(find.text('Item 2/4: run integration tests'), findsOneWidget);
  });

  testWidgets('the status row opens the backlog drawer', (tester) async {
    String? opened;
    await _pump(
      tester,
      sessions: {'t1': _armed()},
      opener: (terminalId) => opened = terminalId,
    );

    await tester.tap(find.text('Nothing queued'));
    await tester.pump();

    expect(opened, 't1');
  });

  testWidgets('with no opener registered the row opens the real drawer', (
    tester,
  ) async {
    // The bar and the drawer are separate files wired only by this default, so
    // without this the row can be inert in the app while every other test here
    // passes against an injected opener. It matters more since the collapse:
    // this row is now the ONLY way to reach the instruction composer.
    await _pump(tester, sessions: {'t1': _armed()});

    await tester.tap(find.text('Nothing queued'));
    await tester.pumpAndSettle();

    expect(find.byType(HandlerBacklogDrawer), findsOneWidget);
    expect(find.byType(HandlerInstructionComposer), findsOneWidget);
  });

  testWidgets('a live park deadline runs a clock that stops on dispose', (
    tester,
  ) async {
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          runState: HandlerRunState.parked,
          parkKind: 'limit',
          parkedUntil: DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        ),
      },
    );
    expect(find.textContaining('Paused (rate limit) · resumes in'), findsOne);

    await tester.pump(const Duration(seconds: 1));
    // Tearing the tree down must take the ticker with it, or the test binding
    // reports a pending timer — the same leak a backgrounded app would carry.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the hint renders under the status line', (tester) async {
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          runState: HandlerRunState.needsYou,
          escalations: _replies(3),
        ),
      },
    );
    expect(
      find.text('Your next message clears all 3 questions, answered or not'),
      findsOneWidget,
    );
  });

  testWidgets('the redirect hint gets a second line to land on', (
    tester,
  ) async {
    // 280px is the narrowest surface this repo mounts handler UI at, and the
    // actionable half of this string is its TAIL — on one ellipsized line the
    // user is told what will not work and never where to go. Asserted through
    // the render object rather than the widget field, since it is AbListRow's
    // DefaultTextStyle that has to carry the allowance down to the Text.
    tester.view.physicalSize = const Size(280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          runState: HandlerRunState.needsYou,
          escalations: [
            _escalation('e1', kind: 'resolve_in_session'),
            _escalation('e2'),
            _escalation('e3'),
          ],
        ),
      },
    );
    final hint = find.text(
      'Answer the prompt in the transcript — '
      'a message here clears the other 2 questions',
    );
    expect(hint, findsOneWidget);
    expect(tester.renderObject<RenderParagraph>(hint).maxLines, 2);
  });

  test('a skipped item never advances the ordinal', () {
    // Skipped and failed close an item without achieving it, so counting them
    // would inflate the progress the bar promises.
    final label = handlerPaStatusLabel(
      _armed(
        backlog: [
          _item('i1', 'run unit tests', 'skipped'),
          _item('i2', 'run the full suite', 'active'),
          _item('i3', 'open a PR', 'queued'),
        ],
      ),
    );
    expect(label, 'Item 1/3: run the full suite');
  });

  test('an exhausted backlog reports completions, not "finished"', () {
    expect(
      handlerPaStatusLabel(
        _armed(
          backlog: [
            _item('i1', 'run tests', 'done'),
            _item('i2', 'open a PR', 'skipped'),
          ],
        ),
      ),
      '1 of 2 done',
    );
  });

  test('nothing active but work left reports what remains', () {
    expect(
      handlerPaStatusLabel(
        _armed(
          backlog: [
            _item('i1', 'run tests', 'done'),
            _item('i2', 'open a PR', 'blocked'),
          ],
        ),
      ),
      '1 of 2 done · 1 left',
    );
  });

  test('a parked session reads as paused with its remaining time', () {
    final now = DateTime(2026, 8, 3, 9);
    expect(
      handlerPaStatusLabel(
        _armed(
          runState: HandlerRunState.parked,
          parkKind: 'limit',
          parkedUntil: now
              .add(const Duration(minutes: 3, seconds: 40))
              .millisecondsSinceEpoch,
        ),
        now: now,
      ),
      'Paused (rate limit) · resumes in 3m 40s',
    );
  });

  test('a park with no deadline promises only the reason', () {
    expect(
      handlerPaStatusLabel(
        _armed(runState: HandlerRunState.parked, parkKind: 'outage'),
      ),
      'Paused (provider outage)',
    );
  });

  // The hint is the whole reason direct input stays UNBLOCKED: the engine
  // already treats a submitted human line as the user taking the wheel
  // (HandlerEngine.onUserReply), and these are its consequences said out loud.
  group('handlerTypingHint', () {
    test('watching warns about nothing, since nothing is displaced', () {
      expect(handlerTypingHint(_armed()), isNull);
    });

    test('one pending question promises clearing, never an answer', () {
      // The engine never inspects the text, so a line retires the row whether
      // or not it addressed the question.
      expect(
        handlerTypingHint(
          _armed(runState: HandlerRunState.needsYou, escalations: _replies(1)),
        ),
        'Your next message clears this question, answered or not',
      );
    });

    test('several pending questions admit that one line clears them all', () {
      // Each pause supersedes the last, so the engine retires the whole
      // free-text list on a submitted line.
      expect(
        handlerTypingHint(
          _armed(runState: HandlerRunState.needsYou, escalations: _replies(4)),
        ),
        'Your next message clears all 4 questions, answered or not',
      );
    });

    test('an in-session prompt sends the user to the transcript', () {
      // onUserReply leaves this row standing, and injected text cannot resolve
      // it either — promising anything else here is what left a blocked agent
      // behind a quiet session.
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [_escalation('e1', kind: 'resolve_in_session')],
          ),
        ),
        'Answer the prompt in the transcript — not here',
      );
    });

    test('a prompt names the questions the same line still clears', () {
      // The redirect alone reads as "typing here does nothing", and the user who
      // types anyway loses the two free-text rows without ever being told.
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('e1'),
              _escalation('e2', kind: 'resolve_in_session'),
              _escalation('e3'),
            ],
          ),
        ),
        'Answer the prompt in the transcript — '
        'a message here clears the other 2 questions',
      );
    });

    test('one question behind a prompt is counted in the singular', () {
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('e1', kind: 'resolve_in_session'),
              _escalation('e2'),
            ],
          ),
        ),
        'Answer the prompt in the transcript — '
        'a message here clears the other question',
      );
    });

    test('several prompts at once are counted, not called "the prompt"', () {
      // Parallel tool calls stop the agent on one permission prompt per call,
      // and the engine raises a row for each — a singular label there sends the
      // user to answer one thing and leaves the agent blocked on the rest.
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('e1', kind: 'resolve_in_session'),
              _escalation('e2', kind: 'resolve_in_session'),
              _escalation('e3'),
            ],
          ),
        ),
        'Answer 2 prompts in the transcript — '
        'a message here clears the other question',
      );
    });

    test('a park says typing ends the wait early', () {
      expect(
        handlerTypingHint(
          _armed(runState: HandlerRunState.parked, parkKind: 'limit'),
        ),
        'Your next message resumes Handler now',
      );
    });

    test('a park holding a prompt promises the unpark, not the resume', () {
      // enterPark never clears escalations, and onUserReply lands such a session
      // back on needs_you — so "resumes Handler now" is a promise the engine
      // refuses to keep.
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.parked,
            parkKind: 'limit',
            escalations: [_escalation('e1', kind: 'resolve_in_session')],
          ),
        ),
        'Your next message ends the pause — the prompt still needs the '
        'transcript',
      );
    });

    test('a report is not counted among the questions a message clears', () {
      // onUserReply keeps a guard_blocked row standing, so counting it would
      // promise clearing the bridge refuses to do.
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('e1'),
              _escalation('b1', kind: 'guard_blocked'),
            ],
          ),
        ),
        'Your next message clears this question, answered or not',
      );
    });

    test('a session standing only on reports warns about nothing', () {
      // needs_you with nothing a typed line would clear: the bar has no promise
      // to make, and the report goes away through its own Dismiss.
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [_escalation('b1', kind: 'guard_blocked')],
          ),
        ),
        isNull,
      );
    });

    test('a report beside a prompt shrinks neither count wrongly', () {
      expect(
        handlerTypingHint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('e1', kind: 'resolve_in_session'),
              _escalation('b1', kind: 'guard_blocked'),
            ],
          ),
        ),
        'Answer the prompt in the transcript — not here',
      );
    });

    test('handling is the one state with a second writer on the session', () {
      expect(
        handlerTypingHint(_armed(runState: HandlerRunState.handling)),
        'Handler is replying — a message now may cross it',
      );
    });
  });
}
