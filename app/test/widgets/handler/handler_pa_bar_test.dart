// The pinned PA bar. It is one status row and nothing else: the instruction
// composer moved into the backlog drawer, because a second field with its own
// send button, pinned under the session composer, read as a rival place to type
// with nothing on either saying who receives it.
import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_state_chip.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/session_mode.dart';
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
  String? parkCause,
  String? roleId,
  String? brief,
  HandlerObservability? observability,
  HandlerAvailability? availability,
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
  parkCause: parkCause,
  roleId: roleId,
  brief: brief,
  observability: observability,
  availability: availability,
);

/// The chip's tone is the whole assertion, and the harness below mounts no
/// palette extension — so read the one the bar itself resolved rather than
/// guessing which fallback is in force.
AbStateChip _chip(WidgetTester tester, String label) =>
    tester.widget<AbStateChip>(find.widgetWithText(AbStateChip, label));

/// The state word is the first span of a rich title, so its tone is only
/// legible off the spans — a `Text` finder would hand back the whole line.
/// The title is the one rich `Text` the bar builds; the subtitle and the chip
/// label both carry plain `data`.
TextSpan _stateSpan(WidgetTester tester) {
  final title = tester.widget<Text>(
    find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
  );
  return (title.textSpan! as TextSpan).children!.first as TextSpan;
}

/// The brief marker carries no text, so the icon it draws is the only thing
/// that identifies it.
final Finder _briefMarker = find.byWidgetPredicate(
  (w) => w is AbIcon && w.icon == AbIcons.comment,
);

HandlerInstructionItem _item(String id, String text, String status) =>
    HandlerInstructionItem(id: id, text: text, status: status, createdAt: 1);

/// [kind] null is the free-text row; 'resolve_in_session' is the option-based
/// prompt only the transcript can resolve; 'guard_blocked' is the report of an
/// action Handler could not take, which only its card's Dismiss retires.
/// [nonBlocking] is the ask — a question Handler put to the user on a pass that
/// had already replied to the agent, which no typed line retires either.
HandlerEscalation _escalation(
  String id, {
  String? kind,
  bool nonBlocking = false,
}) => HandlerEscalation(
  escalationId: id,
  terminalId: 't1',
  question: 'proceed?',
  reasoning: 'because',
  draftReply: 'yes',
  urgency: 'normal',
  at: 1,
  kind: kind,
  nonBlocking: nonBlocking,
);

List<HandlerEscalation> _replies(int n) => [
  for (var i = 0; i < n; i++) _escalation('e$i'),
];

/// [handlerTypingHint] with the session mode defaulted to chat, which is the
/// only half of the copy the cases below are not about. Production has no such
/// default — the bar reads `activeSessionModeProvider` and passes it — because
/// a prompt named for the wrong surface is the failure the parameter exists to
/// prevent.
String? _hint(HandlerSessionState session, {bool isChat = true}) =>
    handlerTypingHint(session, isChat: isChat);

/// The bar sends nothing of its own now, so this needs no project session — only
/// the focused terminal and the handler snapshot the row reads.
///
/// The first-run store is here for the drawer the row opens, not for the bar:
/// the drawer's disclaimer is retired by a persisted flag, and the provider
/// holding it throws unless the store is injected.
/// [lenses] is what the machine has advertised: the four this build knows,
/// unless a test is standing up a machine that never named any (null), which
/// is the only state the bar renders as a dash.
/// [mode] is the focused session's own mode, which decides which surface the
/// hint sends an option-based prompt to — overridden rather than seeded through
/// a session list, since the bar reads only the derived value.
Future<void> _pump(
  WidgetTester tester, {
  required Map<String, HandlerSessionState> sessions,
  HandlerBacklogOpener? opener,
  List<String>? lenses = const ['pm', 'qa', 'critic', 'release'],
  String mode = 'chat',
}) async {
  useInMemoryPrefs();
  final firstRun = await FirstRunStore.open();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        firstRunStoreProvider.overrideWithValue(firstRun),
        activeSessionIdProvider.overrideWith(() => ValueController('t1')),
        activeSessionModeProvider.overrideWithValue(mode),
        handlerStateProvider.overrideWith(
          (ref) => Stream.value(
            const HandlerState.initial().copyWith(
              sessions: sessions,
              lenses: lenses,
            ),
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
  testWidgets('the bar names the lens', (tester) async {
    // The bar is on screen for the whole time a session is armed and is the
    // only place the lens is visible at all, so "no chip" would be a state the
    // user has to be taught to read.
    // As written, not shouted: the sheet this chip opens paints the same four
    // phrases in the same casing, and one lens spelled two ways on two
    // surfaces is read as two settings.
    await _pump(tester, sessions: {'t1': _armed(roleId: 'qa')});
    final chip = _chip(tester, 'Proof it works');
    expect(chip.active, isFalse);
    expect(chip.tone, isNull);
  });

  testWidgets('the default is named as nothing extra', (tester) async {
    // The unnamed lens is still a live setting, and the chip that opens the
    // sheet has to be on screen before the user has ever picked anything.
    await _pump(tester, sessions: {'t1': _armed()});
    expect(find.text('Nothing extra'), findsOneWidget);
    expect(find.text('Proof it works'), findsNothing);
  });

  testWidgets('a lens this build cannot name shows as itself', (tester) async {
    // A newer machine's lens is a real pick this session is judging under.
    // Folding it into the default would report a pick the user never made.
    await _pump(tester, sessions: {'t1': _armed(roleId: 'ship-it')});
    expect(find.text('ship-it'), findsOneWidget);
    expect(find.text('Nothing extra'), findsNothing);
  });

  testWidgets('a brief with no role is shown as your own', (tester) async {
    // Every preset clears the brief on pick (redesign spec §6), so a non-empty
    // brief with no role id can only be the user's own lens.
    await _pump(
      tester,
      sessions: {'t1': _armed(brief: 'watch the migrations')},
    );
    expect(find.text('Your own'), findsOneWidget);
    expect(find.text('Nothing extra'), findsNothing);
  });

  testWidgets('a machine that never advertised lenses is a dash', (
    tester,
  ) async {
    // This chip reads as a live fact about the session. A machine that has
    // never named the lenses it reads is not a machine running the default,
    // and saying so here would advertise a control over nothing.
    await _pump(tester, sessions: {'t1': _armed()}, lenses: null);
    expect(find.text('Nothing extra'), findsNothing);
    expect(_chip(tester, '—').active, isFalse);
  });

  testWidgets('the lens chip is tinted where nothing is being judged', (
    tester,
  ) async {
    // Escalate-only means no decide pass runs at all, so a bar naming a lens
    // in ordinary chrome would say the opposite of what is happening.
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          roleId: 'critic',
          observability: HandlerObservability.escalateOnly,
        ),
      },
    );
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    final chip = _chip(tester, 'What could break');
    expect(chip.tone, p.warning);
    expect(chip.active, isTrue);
  });

  testWidgets('a brief shows a marker beside the lens', (tester) async {
    // A brief is invisible on this row otherwise, so a user who wrote one has
    // no way to tell it survived without opening the sheet.
    await _pump(
      tester,
      sessions: {'t1': _armed(roleId: 'qa', brief: 'watch the migrations')},
    );
    expect(_briefMarker, findsOneWidget);
  });

  testWidgets('no brief leaves the row unmarked', (tester) async {
    await _pump(tester, sessions: {'t1': _armed(roleId: 'qa')});
    expect(_briefMarker, findsNothing);
  });

  testWidgets('the brief marker is part of the same door as the lens', (
    tester,
  ) async {
    // A mark the user cannot follow names something with nowhere to go and
    // read it, so the marker lives INSIDE the gesture the chip opens the
    // settings sheet with. Asserted structurally: a tap landing on nothing
    // would leave the backlog shut too, and pass a test that only watched it.
    String? opened;
    await _pump(
      tester,
      sessions: {'t1': _armed(roleId: 'qa', brief: 'watch the migrations')},
      opener: (terminalId) => opened = terminalId,
    );
    final door = find.ancestor(
      of: find.text('Proof it works'),
      matching: find.byType(GestureDetector),
    );
    expect(find.descendant(of: door, matching: _briefMarker), findsOneWidget);

    await tester.tap(_briefMarker);
    await tester.pump();
    expect(opened, isNull);
  });

  testWidgets('tapping the lens chip does not open the backlog', (
    tester,
  ) async {
    String? opened;
    await _pump(
      tester,
      sessions: {'t1': _armed(roleId: 'qa')},
      opener: (terminalId) => opened = terminalId,
    );
    await tester.tap(find.text('Proof it works'));
    await tester.pump();
    expect(opened, isNull);
  });

  testWidgets('the state leads the line in its own tone', (tester) async {
    // The run state used to live only in the tint of a 12px glyph. The pill
    // that carried the word — `HandlerHeaderControl` — is mounted nowhere, so
    // an armed session had no surface at all saying what Handler was doing.
    await _pump(tester, sessions: {'t1': _armed()});
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    final word = _stateSpan(tester);
    expect(word.text, 'Watching');
    expect(word.style?.color, p.textMuted);
  });

  // `needs_you` is the bridge's one word for two situations, and the tone is
  // the half a user takes in without reading — so it has to move with the
  // word, or the bar reports a stopped agent over one that is still working.
  testWidgets('a question the agent is working past is not a stopped agent', (
    tester,
  ) async {
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          runState: HandlerRunState.needsYou,
          escalations: [_escalation('e1', nonBlocking: true)],
        ),
      },
    );
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    final asked = _stateSpan(tester);
    expect(asked.text, 'Asked you');
    expect(asked.style?.color, p.textSecondary);
  });

  testWidgets('a session that has actually stopped keeps the loud word', (
    tester,
  ) async {
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          runState: HandlerRunState.needsYou,
          escalations: [_escalation('e1')],
        ),
      },
    );
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    final stopped = _stateSpan(tester);
    expect(stopped.text, 'Needs you');
    expect(stopped.style?.color, p.accent);
  });

  testWidgets('an unwatchable session never reads as watching', (tester) async {
    // An armed session whose agent reports nothing sits at `watching` for as
    // long as it stays armed, and this bar is on screen that whole time —
    // "Watching" over a session nobody is watching is the exact claim
    // observability exists to retire.
    await _pump(
      tester,
      sessions: {'t1': _armed(observability: HandlerObservability.unsupported)},
    );
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    final word = _stateSpan(tester);
    expect(word.text, 'Not watched');
    expect(word.style?.color, p.warning);
  });

  testWidgets('monitoring that has not come up yet says so', (tester) async {
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          availability: const HandlerAvailability(
            HandlerAvailabilityState.preparing,
          ),
        ),
      },
    );
    final p = tester.element(find.byType(HandlerPaBar)).antgrid;
    final word = _stateSpan(tester);
    expect(word.text, 'Waiting for agent');
    expect(word.style?.color, p.warning);
  });

  testWidgets('a bridge that reports no availability keeps the plain word', (
    tester,
  ) async {
    // Null is "nobody said". A bridge that predates the field must not read as
    // a broken one — that is the arm which would turn every un-upgraded
    // machine into a bar full of warnings.
    await _pump(tester, sessions: {'t1': _armed()});
    expect(_stateSpan(tester).text, 'Watching');
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
    expect(find.text('Watching · Nothing queued'), findsNothing);
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
    expect(
      find.text('Watching · Item 2/4: run integration tests'),
      findsOneWidget,
    );
  });

  testWidgets('the status row opens the backlog drawer', (tester) async {
    String? opened;
    await _pump(
      tester,
      sessions: {'t1': _armed()},
      opener: (terminalId) => opened = terminalId,
    );

    await tester.tap(find.text('Watching · Nothing queued'));
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

    await tester.tap(find.text('Watching · Nothing queued'));
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
    expect(find.textContaining('Paused · rate limit · resumes in'), findsOne);

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

  testWidgets('the bar reads the session mode, not a fixed surface', (
    tester,
  ) async {
    // The wiring, not the copy: a PTY AskUserQuestion mints the same
    // `resolve_in_session` a chat permission prompt does, and this bar sits
    // directly under the terminal that is showing it. Sending that user to a
    // transcript names a surface their session does not have.
    await _pump(
      tester,
      sessions: {
        't1': _armed(
          runState: HandlerRunState.needsYou,
          escalations: [_escalation('e1', kind: 'resolve_in_session')],
        ),
      },
      mode: 'terminal',
    );
    expect(find.text('Answer the prompt in the terminal'), findsOneWidget);
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
      'rate limit · resumes in 3m 40s',
    );
  });

  // An older bridge sends no cause at all, and the bar must not invent one: all
  // `outage` itself knows is that the engine will retry, so that is all it says.
  test('a park with no deadline promises only the reason', () {
    expect(
      handlerPaStatusLabel(
        _armed(runState: HandlerRunState.parked, parkKind: 'outage'),
      ),
      'temporary failure',
    );
  });

  // The defect this cause exists for: every non-limit park is filed under
  // `outage`, so reading the kind blamed the coding agent's provider for
  // Antgrid's own judge going down.
  test("a judge failure names the judge, not the agent's provider", () {
    expect(
      handlerPaStatusLabel(
        _armed(
          runState: HandlerRunState.parked,
          parkKind: 'outage',
          parkCause: 'judge_failure',
        ),
      ),
      'judge unavailable',
    );
  });

  test("the agent's own failure is named as such", () {
    expect(
      handlerPaStatusLabel(
        _armed(
          runState: HandlerRunState.parked,
          parkKind: 'outage',
          parkCause: 'agent_failure',
        ),
      ),
      'agent error',
    );
  });

  // A newer bridge's cause falls back to the kind's copy rather than printing a
  // wire word at the user.
  test('a cause this build cannot name falls back to the kind', () {
    expect(
      handlerPaStatusLabel(
        _armed(
          runState: HandlerRunState.parked,
          parkKind: 'limit',
          parkCause: 'solar_flare',
        ),
      ),
      'rate limit',
    );
  });

  // The hint is the whole reason direct input stays UNBLOCKED: the engine
  // already treats a submitted human line as the user taking the wheel
  // (HandlerEngine.onUserReply), and these are its consequences said out loud.
  group('handlerTypingHint', () {
    test('watching warns about nothing, since nothing is displaced', () {
      expect(_hint(_armed()), isNull);
    });

    test('one pending question promises clearing, never an answer', () {
      // The engine never inspects the text, so a line retires the row whether
      // or not it addressed the question.
      expect(
        _hint(
          _armed(runState: HandlerRunState.needsYou, escalations: _replies(1)),
        ),
        'Your next message clears this question, answered or not',
      );
    });

    test('several pending questions admit that one line clears them all', () {
      // Each pause supersedes the last, so the engine retires the whole
      // free-text list on a submitted line.
      expect(
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(
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
        _hint(_armed(runState: HandlerRunState.handling)),
        'Handler is replying — a message now may cross it',
      );
    });

    test('an ask alone still warns, because the line reaches the agent', () {
      // The one exemption that is still the user's to answer. A silent arm here
      // would let them type, watch the line land, and believe they had answered
      // a question that never moved.
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [_escalation('a1', nonBlocking: true)],
          ),
        ),
        "Your next message goes to the agent — Handler's question stays open",
      );
    });

    test('an ask beside one question keeps both halves of the promise', () {
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('a1', nonBlocking: true),
              _escalation('e1'),
            ],
          ),
        ),
        'Your next message clears this question, answered or not — '
        "Handler's own question stays open",
      );
    });

    test('an ask is subtracted from the count a line promises to clear', () {
      // The invisible failure this counts against: a missing subtrahend would
      // read as "clears all 3", which is a promise the bridge refuses to keep
      // rather than a hint that failed to appear.
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('a1', nonBlocking: true),
              _escalation('e1'),
              _escalation('e2'),
            ],
          ),
        ),
        'Your next message clears all 2 questions, answered or not — '
        "Handler's own question stays open",
      );
    });

    test('an ask behind a prompt is appended to the redirect once', () {
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('a1', nonBlocking: true),
              _escalation('e1', kind: 'resolve_in_session'),
            ],
          ),
        ),
        'Answer the prompt in the transcript — not here — '
        "Handler's question stays open",
      );
    });

    test('an ask behind a prompt does not inflate the cleared count', () {
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('a1', nonBlocking: true),
              _escalation('e1', kind: 'resolve_in_session'),
              _escalation('e2'),
            ],
          ),
        ),
        'Answer the prompt in the transcript — a message here clears the '
        "other question — Handler's question stays open",
      );
    });

    test('a parked session holding an ask promises only the resume', () {
      // Reachable rather than theoretical: the park timer's nudge counts
      // blocking questions alone, so an ask-only session parks and self-resumes.
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.parked,
            parkKind: 'limit',
            escalations: [_escalation('a1', nonBlocking: true)],
          ),
        ),
        'Your next message resumes Handler now — its question stays open',
      );
    });

    // A PTY agent's AskUserQuestion reaches the same forced escalate as a chat
    // permission prompt (`isBlockingPrompt`, handler/engine.ts), so
    // `resolve_in_session` is minted for a terminal session too — and every
    // line below used to send that user to a transcript their session does not
    // have.
    test('a terminal prompt is answered in the terminal, not a transcript', () {
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [_escalation('e1', kind: 'resolve_in_session')],
          ),
          isChat: false,
        ),
        'Answer the prompt in the terminal',
      );
    });

    test('a terminal prompt drops the "not here" the composer earns', () {
      // The redirect's whole point on a chat slot is that the composer is
      // somewhere other than the permission card. A PTY agent draws its prompt
      // in the very terminal the keystrokes go to, so "not here" would point
      // away from the only place that can answer it.
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [_escalation('e1', kind: 'resolve_in_session')],
          ),
          isChat: false,
        ),
        isNot(contains('not here')),
      );
    });

    test('a terminal prompt says answering it is what clears the lines', () {
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [
              _escalation('e1', kind: 'resolve_in_session'),
              _escalation('e2'),
            ],
          ),
          isChat: false,
        ),
        'Answer the prompt in the terminal — '
        'that also clears the other question',
      );
    });

    test('a parked terminal prompt still needs the terminal', () {
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.parked,
            parkKind: 'limit',
            escalations: [_escalation('e1', kind: 'resolve_in_session')],
          ),
          isChat: false,
        ),
        'Your next message ends the pause — the prompt still needs the '
        'terminal',
      );
    });

    test('a terminal ask keeps the tail the mode does not change', () {
      // Only the prompt arms name a surface; everything else is about the
      // session's own composer and reads identically in both modes.
      expect(
        _hint(
          _armed(
            runState: HandlerRunState.needsYou,
            escalations: [_escalation('a1', nonBlocking: true)],
          ),
          isChat: false,
        ),
        "Your next message goes to the agent — Handler's question stays open",
      );
    });
  });
}
