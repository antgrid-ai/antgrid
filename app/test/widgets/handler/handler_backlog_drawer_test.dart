import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_chip.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/first_run.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/storage/first_run_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/handler/handler_backlog_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

const _tests = HandlerInstructionItem(
  id: 'i1',
  text: 'run the tests',
  status: 'done',
  createdAt: 1,
);
const _commit = HandlerInstructionItem(
  id: 'i2',
  text: 'commit the fix',
  status: 'queued',
  createdAt: 2,
);
const _pr = HandlerInstructionItem(
  id: 'i3',
  text: 'open a PR',
  status: 'queued',
  dependsOn: ['i1', 'i2'],
  createdAt: 3,
);

/// What the extractor made of an instruction. A snapshot retires an outstanding
/// sentence on the backlog having GROWN, so a test that needs to reach the far
/// side of an extraction has to append something — a frame carrying the same
/// list is a frame the instruction had no part in raising.
const _extracted = HandlerInstructionItem(
  id: 'i9',
  text: 'run the tests again',
  status: 'queued',
  createdAt: 9,
);

/// Boots a real [ProjectSession] over a fake transport and queues one
/// `handler:status` snapshot into it, so the drawer reads (and edits) the same
/// state the production service would hold. The snapshot is delivered by the
/// microtask flush inside the first [WidgetTester.pump].
Future<ProjectSession> _armedSession(
  List<HandlerInstructionItem> backlog, {
  bool notifyOnly = false,
  String state = 'watching',
  String goal = 'ship the fix',
}) async {
  useInMemoryPrefs();
  final transport = FakeAgentTransport();
  final session = ProjectSession(
    projectId: 'p',
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: await CachedSessionsStore.open(),
    onClose: () async => transport.dispose(),
  );
  _emitStatus(
    session,
    backlog,
    notifyOnly: notifyOnly,
    state: state,
    goal: goal,
  );
  return session;
}

/// Pushes one `handler:status` snapshot in. The bridge emits one after every
/// handler event on any armed session; what retires an outstanding instruction
/// is this terminal's backlog having grown, so a second call carrying an
/// appended item is how a test gets to the far side of an extraction.
void _emitStatus(
  ProjectSession session,
  List<HandlerInstructionItem> backlog, {
  bool notifyOnly = false,
  String state = 'watching',
  String goal = 'ship the fix',
}) {
  _transportOf(session).emit('handler:status', {
    'projectId': 'p',
    'sessions': [
      {
        'terminalId': 't1',
        'notifyOnly': notifyOnly,
        'state': state,
        'pendingEscalations': 0,
        'armedAt': 1,
        'goal': goal,
        'backlog': [for (final i in backlog) i.toWire()],
      },
    ],
  });
}

FakeAgentTransport _transportOf(ProjectSession session) =>
    session.transport as FakeAgentTransport;

/// The session list the drawer titles itself from. Emitted separately from the
/// handler snapshot because the two are separate wires: a terminal is armed
/// long before — or entirely without — a `session:list` the app has read, and
/// the title has to hold either way.
void _emitSessions(ProjectSession session, {required String name}) {
  _transportOf(session).emit('session:list:result', {
    'projectId': 'p',
    'sessions': [
      {
        'id': 't1',
        'name': name,
        'createdAt': 0,
        'lastUsedAt': 0,
        'archived': false,
        'running': true,
        'mode': 'terminal',
      },
    ],
  });
}

/// [firstRun] carries a pre-dismissed disclaimer in; without one the store
/// starts empty, which is what every other test here wants.
Future<void> _pumpDrawer(
  WidgetTester tester,
  ProjectSession session, {
  FirstRunStore? firstRun,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('p'),
        projectSessionProvider('p').overrideWith((ref) => session),
        firstRunStoreProvider.overrideWithValue(
          firstRun ?? await FirstRunStore.open(),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: HandlerBacklogDrawer(terminalId: 't1')),
      ),
    ),
  );
  await tester.pump();
  await tester.pumpAndSettle();
}

/// The one `handler:configure` the drawer sent, as its backlog item ids.
List<String> _sentIds(ProjectSession session) {
  final sent = _transportOf(
    session,
  ).sent.where((m) => m['type'] == 'handler:configure').toList();
  expect(sent, hasLength(1));
  return [
    for (final i in sent.single['backlog'] as List) (i as Map)['id'] as String,
  ];
}

Map<String, dynamic> _sentConfigure(ProjectSession session) => _transportOf(
  session,
).sent.firstWhere((m) => m['type'] == 'handler:configure');

Future<void> _openMenuFor(WidgetTester tester, int rowIndex) async {
  await tester.tap(find.byTooltip('Item actions').at(rowIndex));
  await tester.pumpAndSettle();
}

List<AbMenuItem> _openMenuItems(WidgetTester tester) => [
  for (final entry in tester.widget<AbMenu>(find.byType(AbMenu)).items)
    if (entry is AbMenuItem) entry,
];

List<String> _openMenuLabels(WidgetTester tester) => [
  for (final entry in _openMenuItems(tester)) entry.label,
];

/// Lets the session cache's write-through debounce fire. A `session:list`
/// schedules one, and a timer still pending when the tree goes down fails the
/// test on an invariant that has nothing to do with what it asserted.
Future<void> _drainSessionCacheFlush(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

/// Lets the snack bar's dismiss timer expire, so it can't outlive the test.
Future<void> _drainSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('deleting an item sends the list without exactly that one', (
    tester,
  ) async {
    final session = await _armedSession([_tests, _commit, _pr]);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 1);
    await _pick(tester, 'Delete');

    expect(_sentIds(session), ['i1', 'i3']);
  });

  testWidgets('moving an item up sends the new order', (tester) async {
    final session = await _armedSession([_tests, _commit, _pr]);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 2);
    await _pick(tester, 'Move up');

    expect(_sentIds(session), ['i1', 'i3', 'i2']);
  });

  testWidgets('move to top lifts an item over every slot in one edit', (
    tester,
  ) async {
    final session = await _armedSession([_tests, _commit, _pr]);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 0);
    // The row already at the head has nowhere to lift to.
    expect(_openMenuLabels(tester), isNot(contains('Move to top')));
    await _pick(tester, 'Move down');
    _transportOf(session).clearSent();

    await _openMenuFor(tester, 2);
    await _pick(tester, 'Move to top');

    // _sentIds insists on exactly one configure: the whole point of the entry
    // is that it costs one round trip and not one per slot.
    expect(_sentIds(session), ['i3', 'i1', 'i2']);
  });

  testWidgets('the first item cannot move up and the last cannot move down', (
    tester,
  ) async {
    final session = await _armedSession([_tests, _commit, _pr]);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 0);
    expect(_openMenuLabels(tester), isNot(contains('Move up')));
    await _pick(tester, 'Move down');

    await _openMenuFor(tester, 2);
    expect(_openMenuLabels(tester), isNot(contains('Move down')));
  });

  testWidgets('removing a dependency drops that id alone and keeps the item', (
    tester,
  ) async {
    final session = await _armedSession([_tests, _commit, _pr]);
    await _pumpDrawer(tester, session);

    // Two dependency rows, in dependsOn order — the second is 'commit the fix'.
    await tester.tap(find.byTooltip('Remove this dependency').at(1));
    await tester.pumpAndSettle();

    final sent = _sentConfigure(session)['backlog'] as List;
    expect(_sentIds(session), ['i1', 'i2', 'i3']);
    final edited = sent.last as Map;
    expect(edited['dependsOn'], ['i1']);
  });

  testWidgets('removing the last dependency omits the key entirely', (
    tester,
  ) async {
    const single = HandlerInstructionItem(
      id: 'i3',
      text: 'open a PR',
      status: 'queued',
      dependsOn: ['i1'],
      createdAt: 3,
    );
    final session = await _armedSession([_tests, single]);
    await _pumpDrawer(tester, session);

    await tester.tap(find.byTooltip('Remove this dependency'));
    await tester.pumpAndSettle();

    final edited = (_sentConfigure(session)['backlog'] as List).last as Map;
    expect(edited.containsKey('dependsOn'), isFalse);
  });

  testWidgets('requeue puts a skipped item back to queued', (tester) async {
    const skipped = HandlerInstructionItem(
      id: 'i2',
      text: 'commit the fix',
      status: 'skipped',
      outcome: 'moot',
      evidence: 'nothing to commit',
      createdAt: 2,
    );
    final session = await _armedSession([_tests, skipped]);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 1);
    await _pick(tester, 'Requeue');

    final edited = (_sentConfigure(session)['backlog'] as List).last as Map;
    expect(edited['status'], 'queued');
    // The skip's outcome and evidence justified the status it was written for.
    expect(edited.containsKey('outcome'), isFalse);
    expect(edited.containsKey('evidence'), isFalse);
  });

  testWidgets('requeue puts a blocked item back to queued', (tester) async {
    const blocked = HandlerInstructionItem(
      id: 'i2',
      text: 'open a PR',
      status: 'blocked',
      dependsOn: ['i1'],
      outcome: 'the test run it waits on has not finished',
      createdAt: 2,
    );
    final session = await _armedSession([_tests, blocked]);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 1);
    await _pick(tester, 'Requeue');

    final edited = (_sentConfigure(session)['backlog'] as List).last as Map;
    expect(edited['status'], 'queued');
    expect(edited.containsKey('outcome'), isFalse);
    // The dependency is left alone: the bridge blocking this again on its next
    // pass is the right answer, and the row already says what it waits on.
    expect(edited['dependsOn'], ['i1']);
  });

  testWidgets('an item behind stalled work is offered no requeue', (
    tester,
  ) async {
    const failed = HandlerInstructionItem(
      id: 'i1',
      text: 'run the tests',
      status: 'failed',
      createdAt: 1,
    );
    const waiting = HandlerInstructionItem(
      id: 'i2',
      text: 'open a PR',
      status: 'blocked',
      dependsOn: ['i1'],
      createdAt: 2,
    );
    final session = await _armedSession([failed, waiting]);
    await _pumpDrawer(tester, session);

    // Dropping the dependency is the action that frees it, and it stays.
    expect(find.byTooltip('Remove this dependency'), findsOneWidget);
    await _openMenuFor(tester, 1);
    // The bridge re-blocks anything waiting on failed work on its next pass, so
    // requeueing here changes the word and nothing else.
    expect(_openMenuLabels(tester), isNot(contains('Requeue')));
    await _pick(tester, 'Delete');
  });

  testWidgets('the waits-on line names a dependency that is itself stuck', (
    tester,
  ) async {
    const blockedDep = HandlerInstructionItem(
      id: 'i1',
      text: 'run the tests',
      status: 'blocked',
      createdAt: 1,
    );
    const waiting = HandlerInstructionItem(
      id: 'i2',
      text: 'open a PR',
      status: 'blocked',
      dependsOn: ['i1'],
      createdAt: 2,
    );
    final session = await _armedSession([blockedDep, waiting]);
    await _pumpDrawer(tester, session);

    // Both rows' own status columns, plus the waits-on line — which is the one
    // saying why the item behind it is offered no requeue.
    expect(find.text('blocked'), findsNWidgets(3));
  });

  testWidgets('requeue is offered for skipped and blocked and no other status', (
    tester,
  ) async {
    const failed = HandlerInstructionItem(
      id: 'i4',
      text: 'deploy',
      status: 'failed',
      createdAt: 4,
    );
    const skipped = HandlerInstructionItem(
      id: 'i5',
      text: 'update the changelog',
      status: 'skipped',
      createdAt: 5,
    );
    const blocked = HandlerInstructionItem(
      id: 'i6',
      text: 'tag the release',
      status: 'blocked',
      createdAt: 6,
    );
    final session = await _armedSession([
      _tests,
      _commit,
      failed,
      skipped,
      blocked,
    ]);
    await _pumpDrawer(tester, session);

    for (final row in [0, 1, 2]) {
      await _openMenuFor(tester, row);
      expect(_openMenuLabels(tester), isNot(contains('Requeue')));
      await _pick(tester, 'Delete');
      _transportOf(session).clearSent();
    }
    // Neither reached an outcome: one's precondition did not hold, the other is
    // waiting on something that has not cleared.
    for (final row in [3, 4]) {
      await _openMenuFor(tester, row);
      expect(_openMenuLabels(tester), contains('Requeue'));
      await _pick(tester, 'Delete');
      _transportOf(session).clearSent();
    }
  });

  testWidgets('the edit carries the session\'s own notifyOnly', (tester) async {
    final session = await _armedSession([_tests, _commit], notifyOnly: true);
    await _pumpDrawer(tester, session);

    await _openMenuFor(tester, 0);
    await _pick(tester, 'Delete');

    final sent = _sentConfigure(session);
    expect(sent['notifyOnly'], true);
    // A goal riding along would re-extract the backlog on the bridge.
    expect(sent.containsKey('goal'), isFalse);
  });

  testWidgets('nothing in the drawer authors a dependency', (tester) async {
    final session = await _armedSession([_tests, _commit, _pr]);
    await _pumpDrawer(tester, session);

    // Spec §3.3: a dependency may be dropped, never written. Nothing renders an
    // add affordance, and every menu entry is a drop/move/requeue.
    expect(
      tester
          .widgetList<AbIcon>(find.byType(AbIcon))
          .where((i) => i.icon == AbIcons.add),
      isEmpty,
    );
    expect(find.textContaining('epend'), findsNothing);
    for (final row in [0, 1, 2]) {
      await _openMenuFor(tester, row);
      expect(
        _openMenuLabels(tester),
        everyElement(
          isIn(['Move to top', 'Move up', 'Move down', 'Requeue', 'Delete']),
        ),
      );
      await _pick(tester, 'Delete');
      _transportOf(session).clearSent();
    }
  });

  testWidgets('a row says what happened, or what it is waiting on', (
    tester,
  ) async {
    const finished = HandlerInstructionItem(
      id: 'i1',
      text: 'run the tests',
      status: 'done',
      condition: 'the branch is dirty',
      outcome: 'all 41 tests passed',
      evidence: '41 passed, 0 failed',
      createdAt: 1,
    );
    const waiting = HandlerInstructionItem(
      id: 'i2',
      text: 'open a PR',
      status: 'queued',
      condition: 'the tests pass',
      createdAt: 2,
    );
    final session = await _armedSession([finished, waiting]);
    await _pumpDrawer(tester, session);

    expect(find.text('all 41 tests passed'), findsOneWidget);
    // The gate is the question the outcome has already answered.
    expect(find.textContaining('the branch is dirty'), findsNothing);
    expect(find.text('only if the tests pass'), findsOneWidget);
    // Evidence backs the outcome; it is not a second subtitle.
    expect(find.textContaining('41 passed, 0 failed'), findsNothing);
  });

  testWidgets('an empty backlog renders its own state, not a broken list', (
    tester,
  ) async {
    final session = await _armedSession(const []);
    await _pumpDrawer(tester, session);

    expect(find.byType(AbEmptyState), findsOneWidget);
    expect(find.byTooltip('Item actions'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  // A session with no goal reaching this state is an adopted session, an arm
  // after a restart, an empty composer, or a list the user emptied. Handler is
  // live in every one of them, which is the fact the copy has to carry.
  testWidgets('an empty list asks for the first instruction, not for pity', (
    tester,
  ) async {
    final session = await _armedSession(const [], goal: '');
    await _pumpDrawer(tester, session);

    // Spelled out rather than compared against a constant: this is the whole
    // content of the surface at this moment, so a rewrite has to fail here.
    expect(
      find.text("Add what you want done while you're away."),
      findsOneWidget,
    );
    expect(
      find.text(
        'Handler already answers what the agent pauses on. A backlog is the '
        'work it takes on by itself.',
      ),
      findsOneWidget,
    );
    // No second route to the one action: the presets and the field below are
    // it, and a button here would give that action a second name.
    expect(find.byTooltip('Add to backlog'), findsOneWidget);
  });

  // The window between a seeded arm and its extraction landing, which is the
  // likeliest moment of all for this sheet to be open. Inviting the user to add
  // what they want done here gets the session's own opening sentence retyped,
  // and the extraction already running appends it a second time.
  testWidgets('an empty list under a goal points at the goal, not at the field', (
    tester,
  ) async {
    final session = await _armedSession(const []);
    await _pumpDrawer(tester, session);

    expect(find.text('Working towards: ship the fix'), findsOneWidget);
    expect(find.text('Nothing queued beyond the goal above.'), findsOneWidget);
    expect(
      find.text("Add what you want done while you're away."),
      findsNothing,
    );
  });

  // A notify-only session escalates every pause and injects nothing, so a
  // backlog on one is a list the user works through themselves.
  testWidgets('a notify-only empty list does not promise autonomous work', (
    tester,
  ) async {
    final session = await _armedSession(const [], notifyOnly: true, goal: '');
    await _pumpDrawer(tester, session);

    expect(
      find.text(
        'Notify only on this session — every pause comes to you, and nothing '
        'here is acted on while you are away.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('takes on by itself'), findsNothing);
  });

  testWidgets('a terminal with no armed session says so, and asks nothing', (
    tester,
  ) async {
    final session = await _armedSession([_tests]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          selectedRegistrationIdProvider.overrideWithValue('p'),
          projectSessionProvider('p').overrideWith((ref) => session),
          firstRunStoreProvider.overrideWithValue(await FirstRunStore.open()),
        ],
        child: const MaterialApp(
          home: Scaffold(body: HandlerBacklogDrawer(terminalId: 'other')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('not armed'), findsOneWidget);
    // Nothing here would receive an instruction, so the invitation is withheld
    // rather than printed over a session that cannot act on it.
    expect(find.textContaining("while you're away"), findsNothing);
    // The way out, worded exactly as the Handler tab words it.
    expect(
      find.text('Arm it with the shield at the end of the top bar.'),
      findsOneWidget,
    );
  });

  group('naming the session being edited', () {
    testWidgets('the title carries the session this backlog belongs to', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      _emitSessions(session, name: 'fix the login bug');
      await _pumpDrawer(tester, session);

      expect(find.text('Backlog · fix the login bug'), findsOneWidget);
      await _drainSessionCacheFlush(tester);
    });

    testWidgets('an unnamed terminal keeps the surface name, not its id', (
      tester,
    ) async {
      // No session list has landed, so the tab's own resolver would fall back
      // to the raw terminal id. In a sheet showing one session that is a string
      // with nothing to tell apart, so it is withheld.
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      expect(find.text('Backlog'), findsOneWidget);
      expect(find.textContaining('t1'), findsNothing);
    });
  });

  // The instruction field and the presets live here rather than pinned above
  // the composer, so this is where the load-bearing assertion now sits: the
  // message TYPE a preset chip produces. A chip that grew its own verb would
  // route around every rule that applies to instructions.
  group('instructing', () {
    List<Map<String, dynamic>> instructs(ProjectSession session) => _transportOf(
      session,
    ).sent.where((m) => m['type'] == 'handler:instruct').toList();

    /// The one `handler:instruct` the drawer sent.
    Map<String, dynamic> sentInstruct(ProjectSession session) =>
        instructs(session).single;

    testWidgets('a preset chip sends handler:instruct with its own sentence', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Clean Build'));
      await tester.pump();

      final sent = sentInstruct(session);
      // Not a chip-specific verb: the chip is indistinguishable on the wire
      // from the user typing the same words.
      expect(sent['terminalId'], 't1');
      expect(sent['text'], 'Clean Build');
    });

    testWidgets('every preset chip is offered', (tester) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      for (final preset in handlerPresetInstructions) {
        expect(find.text(preset), findsOneWidget);
      }
    });

    testWidgets('and every one of them stays on a narrow phone', (
      tester,
    ) async {
      // `find.text` above passes on a preset parked off the right edge — a
      // horizontal strip builds all its children whether or not any is
      // reachable. Geometry is the only thing that can tell the two apart, and
      // this width is where the fourth chip used to fall off.
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      for (final preset in handlerPresetInstructions) {
        expect(
          tester.getRect(find.text(preset)).right,
          lessThanOrEqualTo(320.0),
          reason: preset,
        );
      }

      // Reachable, not merely laid out: the last one still sends.
      await tester.tap(find.text(handlerPresetInstructions.last));
      await tester.pump();
      expect(sentInstruct(session)['text'], handlerPresetInstructions.last);
    });

    testWidgets('typed text sends handler:instruct and clears the field', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.enterText(find.byType(AbTextField), 'also update the docs');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      expect(sentInstruct(session)['text'], 'also update the docs');
      // The field is emptied; the sentence itself is not gone — it moves to
      // the list, which is the other half of this same submit.
      expect(
        tester.widget<AbTextField>(find.byType(AbTextField)).controller!.text,
        isEmpty,
      );
    });

    testWidgets('a sent instruction sits in the list until a status lands', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.enterText(find.byType(AbTextField), 'also update the docs');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      // In the user's own words, at the tail — the slot appendItems will fill
      // with whatever the extractor makes of them.
      expect(find.text('also update the docs'), findsOneWidget);
      expect(find.text('adding'), findsOneWidget);
      // Nothing to reorder or drop: the item is not in the bridge's list yet.
      expect(find.byTooltip('Item actions'), findsOneWidget);

      _emitStatus(session, [
        _tests,
        const HandlerInstructionItem(
          id: 'i9',
          text: 'update the docs',
          status: 'queued',
          createdAt: 9,
        ),
      ]);
      await tester.pump();

      // The extractor rewrote the sentence, which is why the row it replaces
      // could never have been matched to it — the snapshot retires it wholesale.
      expect(find.text('also update the docs'), findsNothing);
      expect(find.text('adding'), findsNothing);
      expect(find.text('update the docs'), findsOneWidget);
    });

    testWidgets('a first instruction stands in for the empty state', (
      tester,
    ) async {
      final session = await _armedSession(const []);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();

      expect(find.textContaining('lands here'), findsNothing);
      // Twice: the chip that sent it, and the row it is now waiting in.
      expect(find.text('Run Tests'), findsNWidgets(2));
    });

    testWidgets('a repeated send is refused until the snapshot lands', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      // The chip, never the bare text: once the send lands, the sentence is on
      // screen twice — on the chip and in the row waiting for its items.
      final chip = find.widgetWithText(AbChip, 'Run Tests');
      await tester.tap(chip);
      await tester.pump();
      await tester.tap(chip);
      await tester.pump();

      // The bridge appends and absorbs no duplicate, so a second identical
      // send is a second copy of the work in the backlog.
      expect(instructs(session), hasLength(1));

      // The second tap moves something on screen. Without it the chip is
      // indistinguishable from a broken button — the list is unchanged, and the
      // row waiting at the tail may be scrolled well out of sight.
      expect(find.text('Already adding "Run Tests".'), findsOneWidget);

      _emitStatus(session, [_tests, _extracted]);
      await tester.pump();
      await tester.tap(chip);
      await tester.pump();

      // The debounce lasts exactly as long as the ambiguity: once the bridge
      // has spoken, asking for the same thing again is a real second ask.
      expect(instructs(session), hasLength(2));
      expect(find.text('Already adding "Run Tests".'), findsNothing);
    });

    testWidgets('a duplicate typed send keeps the words and says why', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.widgetWithText(AbChip, 'Run Tests'));
      await tester.pump();
      await tester.enterText(find.byType(AbTextField), 'Run Tests');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      expect(instructs(session), hasLength(1));
      // The field keeps what was typed: a clear on a send that did not happen
      // takes the user's words away and leaves an unchanged list behind.
      expect(
        tester.widget<AbTextField>(find.byType(AbTextField)).controller!.text,
        'Run Tests',
      );
      expect(find.text('Already adding "Run Tests".'), findsOneWidget);
    });

    testWidgets('a second tap on send has nothing left to send', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.enterText(find.byType(AbTextField), 'also update the docs');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      expect(instructs(session), hasLength(1));
    });

    testWidgets('a whitespace-only submit sends nothing', (tester) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);
      final before = _transportOf(session).sent.length;

      await tester.enterText(find.byType(AbTextField), '   ');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      expect(_transportOf(session).sent.length, before);
    });

    testWidgets('a parked session keeps the chips and input live', (
      tester,
    ) async {
      // Spec §4.4: stacking while parked is the point — the bridge queues it.
      final session = await _armedSession([_tests], state: 'parked');
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();

      expect(sentInstruct(session)['text'], 'Run Tests');
    });

    testWidgets('an unarmed terminal is offered no field to instruct through', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedRegistrationIdProvider.overrideWithValue('p'),
            projectSessionProvider('p').overrideWith((ref) => session),
          ],
          child: const MaterialApp(
            home: Scaffold(body: HandlerBacklogDrawer(terminalId: 'other')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing is supervising that terminal, so an instruction would be sent
      // into a session that cannot run it.
      expect(find.byType(AbTextField), findsNothing);
      expect(find.text(handlerDisclaimerText), findsNothing);
    });

    testWidgets('the drawer carries the disclaimer, worded as §5.5 has it', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      // Spelled out rather than compared against the constant: the wording is
      // the spec's, so a rewrite of it has to fail here.
      expect(
        find.text(
          "Handler acts on your behalf while you're away and can make mistakes. "
          'Flagged actions are listed in the activity log and can be undone.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the disclaimer reads as chrome, from the token', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      final disclaimer = find.text(handlerDisclaimerText);
      final p = tester.element(disclaimer).antgrid;
      expect(
        tester.widget<Text>(disclaimer).style,
        AbTokens.sansStyle(fontSize: AbTokens.fontXxs, color: p.textMuted),
      );
    });

    testWidgets('closing the disclaimer takes it away with nothing left', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.byTooltip("Dismiss — won't show again"));
      await tester.pumpAndSettle();

      expect(find.text(handlerDisclaimerText), findsNothing);
      // No stand-in: the Undo list the sentence points at carries its own
      // pinned header one layer up, so a residual control here would hold
      // nothing but a line the user has just closed.
      expect(find.byTooltip("Dismiss — won't show again"), findsNothing);
    });

    testWidgets('a closed disclaimer does not come back on the next open', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      final firstRun = await FirstRunStore.open();
      await firstRun.write(
        const FirstRunState(handlerDisclaimerDismissed: true),
      );

      await _pumpDrawer(tester, session, firstRun: firstRun);

      expect(find.text(handlerDisclaimerText), findsNothing);
      // Everything the sheet is FOR is untouched — the retirement is of one
      // standing notice, not of the footer it stood in.
      expect(find.byType(AbTextField), findsOneWidget);
      expect(find.text(handlerPresetInstructions.first), findsOneWidget);
    });
  });

  // An edit is a wholesale replace and an instruction appends behind it, so
  // anything sent in the gap deletes what the user just asked for. These pin
  // both halves: that nothing gets out, and that the user is told why.
  group('holding edits while an instruction lands', () {
    List<Map<String, dynamic>> configures(ProjectSession session) =>
        _transportOf(
          session,
        ).sent.where((m) => m['type'] == 'handler:configure').toList();

    // Spelled out rather than compared against the function: this is copy the
    // user reads at the one moment they are owed an explanation, so a rewrite
    // of it has to fail here.
    const oneOutstanding =
        'Still adding "Run Tests" — editing is paused until it lands.';

    testWidgets('the reason stands above the list, not behind a tap', (
      tester,
    ) async {
      final session = await _armedSession([_tests, _commit, _pr]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();

      // On a phone this drawer is a modal sheet, which paints over the snack
      // bar its own ScaffoldMessenger renders, and a tooltip is long-press
      // only — so nothing delivered on a tap arrives. The line is on screen
      // before anything held is touched, and leaves when the hold does.
      expect(find.text(oneOutstanding), findsOneWidget);

      _emitStatus(session, [_tests, _commit, _pr, _extracted]);
      await tester.pump();

      expect(find.text(oneOutstanding), findsNothing);
    });

    testWidgets('every edit on a row is held, and each says why', (
      tester,
    ) async {
      final session = await _armedSession([_tests, _commit, _pr]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();

      await _openMenuFor(tester, 2);
      // Still listed — the action applies, it is the moment that doesn't, and
      // a shorter menu would answer "why can't I move this" with nothing.
      expect(_openMenuLabels(tester), contains('Move up'));
      for (final entry in _openMenuItems(tester)) {
        expect(entry.enabled, isFalse, reason: entry.label);
        expect(entry.disabledReason, oneOutstanding, reason: entry.label);
      }

      await _pick(tester, 'Delete');

      expect(configures(session), isEmpty);
      await _drainSnackBar(tester);
    });

    testWidgets('the same edit goes through once the snapshot lands', (
      tester,
    ) async {
      final session = await _armedSession([_tests, _commit, _pr]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();
      _emitStatus(session, [_tests, _commit, _pr, _extracted]);
      await tester.pump();

      await _openMenuFor(tester, 1);
      for (final entry in _openMenuItems(tester)) {
        expect(entry.enabled, isTrue, reason: entry.label);
      }
      await _pick(tester, 'Delete');

      expect(_sentIds(session), ['i1', 'i3', 'i9']);
    });

    testWidgets('dropping a dependency is held on the same terms', (
      tester,
    ) async {
      final session = await _armedSession([_tests, _commit, _pr]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();

      // Disabled outright rather than tinted disabled over a live control: the
      // reason is standing above the list, so this button has nothing left to
      // promise and must not offer a cursor, a hover fill or a focus ring.
      final held = tester
          .widgetList<AbIconButton>(find.byType(AbIconButton))
          .where((b) => b.tooltip == oneOutstanding);
      expect(held, isNotEmpty);
      expect(held.every((b) => b.onTap == null), isTrue);

      await tester.tap(find.byTooltip(oneOutstanding).first);
      await tester.pumpAndSettle();

      expect(configures(session), isEmpty);
    });

    testWidgets('two outstanding instructions are counted, not quoted', (
      tester,
    ) async {
      final session = await _armedSession([_tests, _commit]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();
      await tester.tap(find.text('Commit'));
      await tester.pump();

      const twoOutstanding =
          'Still adding 2 instructions — editing is paused until they land.';
      expect(find.text(twoOutstanding), findsOneWidget);

      await _openMenuFor(tester, 0);
      expect(_openMenuItems(tester).first.disabledReason, twoOutstanding);
    });

    testWidgets('a new instruction is not held — the bridge appends it', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.tap(find.text('Run Tests'));
      await tester.pump();
      await tester.enterText(find.byType(AbTextField), 'also update the docs');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      // Two appends cannot erase each other, and the extraction chain is
      // per-terminal and serial — so stacking work is exactly what this
      // surface is for, lock or no lock.
      expect(
        _transportOf(
          session,
        ).sent.where((m) => m['type'] == 'handler:instruct'),
        hasLength(2),
      );
    });
  });
}
