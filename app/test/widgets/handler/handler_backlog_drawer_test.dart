import 'package:antgrid/design/ab_colors.dart';
import 'package:antgrid/design/ab_icons.dart';
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_menu.dart';
import 'package:antgrid/design/widgets/ab_text_field.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
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

/// Boots a real [ProjectSession] over a fake transport and queues one
/// `handler:status` snapshot into it, so the drawer reads (and edits) the same
/// state the production service would hold. The snapshot is delivered by the
/// microtask flush inside the first [WidgetTester.pump].
Future<ProjectSession> _armedSession(
  List<HandlerInstructionItem> backlog, {
  bool notifyOnly = false,
  String state = 'watching',
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
  transport.emit('handler:status', {
    'projectId': 'p',
    'sessions': [
      {
        'terminalId': 't1',
        'notifyOnly': notifyOnly,
        'state': state,
        'pendingEscalations': 0,
        'armedAt': 1,
        'goal': 'ship the fix',
        'backlog': [for (final i in backlog) i.toWire()],
      },
    ],
  });
  return session;
}

FakeAgentTransport _transportOf(ProjectSession session) =>
    session.transport as FakeAgentTransport;

Future<void> _pumpDrawer(WidgetTester tester, ProjectSession session) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('p'),
        projectSessionProvider('p').overrideWith((ref) => session),
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

List<String> _openMenuLabels(WidgetTester tester) => [
  for (final entry in tester.widget<AbMenu>(find.byType(AbMenu)).items)
    if (entry is AbMenuItem) entry.label,
];

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

  testWidgets('requeue is offered for skipped items and no other status', (
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
    final session = await _armedSession([_tests, _commit, failed, skipped]);
    await _pumpDrawer(tester, session);

    for (final row in [0, 1, 2]) {
      await _openMenuFor(tester, row);
      expect(_openMenuLabels(tester), isNot(contains('Requeue')));
      await _pick(tester, 'Delete');
      _transportOf(session).clearSent();
    }
    await _openMenuFor(tester, 3);
    expect(_openMenuLabels(tester), contains('Requeue'));
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
        everyElement(isIn(['Move up', 'Move down', 'Requeue', 'Delete'])),
      );
      await _pick(tester, 'Delete');
      _transportOf(session).clearSent();
    }
  });

  testWidgets('an empty backlog renders its own state, not a broken list', (
    tester,
  ) async {
    final session = await _armedSession(const []);
    await _pumpDrawer(tester, session);

    expect(find.textContaining('Nothing queued'), findsOneWidget);
    expect(find.byTooltip('Item actions'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a terminal with no armed session says so', (tester) async {
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

    expect(find.textContaining('not armed'), findsOneWidget);
  });

  // The instruction field and the presets live here rather than pinned above
  // the composer, so this is where the load-bearing assertion now sits: the
  // message TYPE a preset chip produces. A chip that grew its own verb would
  // route around every rule that applies to instructions.
  group('instructing', () {
    /// The one `handler:instruct` the drawer sent.
    Map<String, dynamic> sentInstruct(ProjectSession session) => _transportOf(
      session,
    ).sent.where((m) => m['type'] == 'handler:instruct').single;

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

    testWidgets('typed text sends handler:instruct and clears the field', (
      tester,
    ) async {
      final session = await _armedSession([_tests]);
      await _pumpDrawer(tester, session);

      await tester.enterText(find.byType(AbTextField), 'also update the docs');
      await tester.tap(find.byTooltip('Add to backlog'));
      await tester.pump();

      expect(sentInstruct(session)['text'], 'also update the docs');
      expect(find.text('also update the docs'), findsNothing);
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
  });
}
