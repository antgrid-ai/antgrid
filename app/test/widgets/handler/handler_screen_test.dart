import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/models/handler_state.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/handler_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/handler/handler_blocked_action_card.dart';
import 'package:antgrid/widgets/handler/handler_decision_card.dart';
import 'package:antgrid/widgets/handler/handler_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/prefs_test_mock.dart';

HandlerSessionState sessionState(
  String terminalId, {
  String? judgeTool,
  String? judgeModel,
  HandlerObservability? observability,
}) => HandlerSessionState(
  terminalId: terminalId,
  notifyOnly: false,
  runState: HandlerRunState.watching,
  pendingEscalations: 0,
  armedAt: 1,
  goal: 'summary',
  backlog: const [],
  escalations: const [],
  judgeTool: judgeTool,
  judgeModel: judgeModel,
  observability: observability,
);

HandlerState stateWith({
  String? defaultTool,
  required Map<String, HandlerSessionState> sessions,
}) => HandlerState.initial().copyWith(
  defaultTool: defaultTool,
  sessions: sessions,
);

Map<String, dynamic> snapshotJson({
  String snapshotId = 's1',
  String state = 'available',
  String? detail,
}) => {
  'projectId': 'p',
  'snapshotId': snapshotId,
  'terminalId': 't1',
  'at': 1,
  'action': 'force_push',
  'trigger': 'git push --force origin feat/x',
  'summary': 'pre-push SHA abc1234 recorded',
  'state': state,
  'detail': ?detail,
};

const approveText = 'yes, use bun for the new package';
const rejectText = 'no, keep vitest';

List<Map<String, dynamic>> choicesJson() => [
  {'choiceId': 'approve', 'label': 'Approve', 'text': approveText},
  {'choiceId': 'reject', 'label': 'Reject', 'text': rejectText},
];

/// The one-shot `handler:escalation` push.
Map<String, dynamic> escalationJson({List<Map<String, dynamic>>? choices}) => {
  'projectId': 'p',
  'escalationId': 'e1',
  'terminalId': 't1',
  'question': 'bun or vitest?',
  'reasoning': 'Affects CI wiring.',
  'draftReply': 'use bun',
  'urgency': 'high',
  'choices': ?choices,
};

/// A `handler:status` snapshot for one armed session. [escalations] rides the
/// session the way the bridge replays unanswered ones on reconnect — the other
/// of the two paths that can produce a card.
Map<String, dynamic> armedStatusJson({
  List<Map<String, dynamic>> escalations = const [],
}) => {
  'projectId': 'p',
  'sessions': [
    {
      'terminalId': 't1',
      'notifyOnly': false,
      'state': escalations.isEmpty ? 'watching' : 'needs_you',
      'pendingEscalations': escalations.length,
      'armedAt': 1,
      'goal': 'ship it',
      'backlog': [],
      'escalations': escalations,
    },
  ],
};

/// The advert crosses the transport, the router and the service before the
/// provider rebuilds the screen — one frame short and the row is not there yet.
Future<void> pumpDelivery(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// Mounts the screen over a REAL [HandlerService], so an undo row is only
/// reachable if the bridge's own wire message produces it and the tap puts a
/// `handler:undo` on the transport. A stubbed state would prove neither half.
Future<FakeAgentTransport> pumpLiveHandlerScreen(WidgetTester tester) async {
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
  final service = HandlerService.fromSession(projectSession);
  final heavy = projectSession.heavyStream.listen((_) {}); // unpause the gate
  addTearDown(() async {
    await heavy.cancel();
    await service.dispose();
    await projectSession.close();
  });

  final container = ProviderContainer(
    overrides: [
      // serviceWhenReady gates on a focused id AND a resolved session before it
      // reads the façade, so without both of these the tap is a silent no-op.
      selectedRegistrationIdProvider.overrideWithValue('p'),
      projectSessionProvider.overrideWith((ref, id) async => projectSession),
      handlerServiceProvider.overrideWithValue(service),
      handlerStateProvider.overrideWith((ref) => service.stateStream),
    ],
  );
  addTearDown(container.dispose);
  await container.read(projectSessionProvider('p').future);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
    ),
  );
  await tester.pump();
  return transport;
}

Future<void> pumpHandlerScreen(WidgetTester tester, HandlerState state) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        handlerStateProvider.overrideWith((ref) => Stream.value(state)),
      ],
      child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
    ),
  );
  await tester.pump();
}

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

  testWidgets('pending escalation + activity render in their sections', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const esc = HandlerEscalation(
      escalationId: 'e1',
      terminalId: 't1',
      question: 'bun or vitest?',
      reasoning: 'r',
      draftReply: 'use bun',
      urgency: 'high',
      at: 1,
    );
    const rec = HandlerActivityRecord(
      recordId: 'r1',
      at: 1,
      terminalId: 't1',
      decision: 'handle',
      reason: 'auto-answered the lint prompt',
    );
    const session = HandlerSessionState(
      terminalId: 't1',
      notifyOnly: false,
      runState: HandlerRunState.needsYou,
      pendingEscalations: 1,
      armedAt: 1,
      goal: '',
      backlog: [],
      escalations: [esc],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          handlerStateProvider.overrideWith(
            (ref) => Stream.value(
              const HandlerState.initial().copyWith(
                sessions: {'t1': session},
                escalations: [esc],
                activity: [rec],
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: HandlerScreen())),
      ),
    );
    await tester.pump();
    expect(find.textContaining('bun or vitest?'), findsOneWidget);
    expect(
      find.textContaining('auto-answered the lint prompt'),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('park and resume render as activity rows', (tester) async {
    final wake = DateTime(2026, 7, 31, 14, 5);
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
        activity: [
          HandlerActivityRecord(
            recordId: 'r1',
            at: 1,
            terminalId: 't1',
            decision: 'parked',
            reason: 'rate_limit',
            detail: wake.toIso8601String(),
          ),
          const HandlerActivityRecord(
            recordId: 'r2',
            at: 2,
            terminalId: 't1',
            decision: 'resumed',
            reason: 'park timer elapsed',
          ),
        ],
      ),
    );
    expect(find.textContaining('Paused: rate_limit'), findsOneWidget);
    expect(find.textContaining('14:05'), findsOneWidget);
    expect(find.textContaining('Resumed: park timer elapsed'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('armed session row shows its judge chip', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1', judgeTool: 'codex')}),
    );
    expect(find.text('codex'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the backlog renders with its done count', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': HandlerSessionState(
            terminalId: 't1',
            notifyOnly: false,
            runState: HandlerRunState.watching,
            pendingEscalations: 0,
            armedAt: 1,
            goal: 'get the tests passing',
            backlog: const [
              HandlerInstructionItem(
                id: 'i1',
                text: 'run the tests',
                status: 'done',
                createdAt: 1,
              ),
              HandlerInstructionItem(
                id: 'i2',
                text: 'open a PR',
                status: 'blocked',
                createdAt: 2,
              ),
            ],
            escalations: const [],
          ),
        },
      ),
    );
    expect(find.text('get the tests passing'), findsOneWidget);
    expect(find.text('run the tests'), findsOneWidget);
    // `blocked` is not progress — only `done` counts towards the pill.
    expect(find.textContaining('1 of 2 done'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('every item outcome gets its own activity label', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
        activity: const [
          HandlerActivityRecord(
            recordId: 'r1',
            at: 1,
            terminalId: 't1',
            decision: 'item_done',
            reason: 'run the tests',
          ),
          HandlerActivityRecord(
            recordId: 'r2',
            at: 2,
            terminalId: 't1',
            decision: 'item_skipped',
            reason: 'open a PR',
          ),
          HandlerActivityRecord(
            recordId: 'r3',
            at: 3,
            terminalId: 't1',
            decision: 'goal_edited',
            reason: 'ship it',
          ),
        ],
      ),
    );
    expect(find.textContaining('Done: run the tests'), findsOneWidget);
    expect(find.textContaining('Skipped: open a PR'), findsOneWidget);
    expect(find.text('Goal edited'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  // A refused completion moves nothing, so the status snapshot after it is
  // identical to the one before — this row is the only trace the user gets of a
  // session that will now not wrap up on its own.
  testWidgets('a refused completion renders with its reason and detail', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
        activity: const [
          HandlerActivityRecord(
            recordId: 'r1',
            at: 1,
            terminalId: 't1',
            decision: 'evidence_rejected',
            reason: 'run /code-review --fix',
            detail: 'done needs evidence showing /code-review itself being run',
          ),
        ],
      ),
    );
    expect(
      find.textContaining('Completion not verified: run /code-review --fix'),
      findsOneWidget,
    );
    expect(
      find.textContaining('showing /code-review itself being run'),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('session without a judge override shows the resolved default', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        defaultTool: 'claude-code',
        sessions: {'t1': sessionState('t1')},
      ),
    );
    expect(find.text('claude-code'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a snapshot advert becomes a one-tap undo on the wire', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:snapshot', snapshotJson());
    await pumpDelivery(tester);

    expect(find.text('Force push'), findsOneWidget);
    expect(find.text('git push --force origin feat/x'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pump();

    final sent = t.sent.where((m) => m['type'] == 'handler:undo').toList();
    expect(sent, hasLength(1));
    expect(sent.single['projectId'], 'p');
    expect(sent.single['snapshotId'], 's1');
  });

  testWidgets('a spent undo offers no tap, and a re-advert replaces its row', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:snapshot', snapshotJson());
    await pumpDelivery(tester);
    t.emit('handler:snapshot', snapshotJson(state: 'undone'));
    await pumpDelivery(tester);

    // The advert is re-sent per state change, so the spent row must REPLACE the
    // live one rather than sit beside it.
    expect(find.text('Undo'), findsNothing);
    expect(find.text('Undone'), findsOneWidget);

    await tester.tap(find.text('Undone'));
    await tester.pump();
    expect(t.sent.where((m) => m['type'] == 'handler:undo'), isEmpty);
  });

  testWidgets('a failed undo stays retryable and names the reason', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit(
      'handler:snapshot',
      snapshotJson(state: 'failed', detail: 'remote rejected the push'),
    );
    await pumpDelivery(tester);

    expect(find.text('remote rejected the push'), findsOneWidget);
    await tester.tap(find.text('Retry undo'));
    await tester.pump();
    expect(t.sent.where((m) => m['type'] == 'handler:undo'), hasLength(1));
  });

  testWidgets('undo offers outlive the last armed session', (tester) async {
    // The wrap-up is read hours after the disarm — an empty state here would
    // hide the offer at exactly the moment it matters.
    await pumpHandlerScreen(
      tester,
      const HandlerState.initial().copyWith(
        snapshots: const [
          HandlerSnapshot(
            snapshotId: 's1',
            terminalId: 't1',
            at: 1,
            action: 'reset_hard',
            trigger: 'git reset --hard HEAD~1',
            summary: 'stashed 3 files',
            state: 'available',
          ),
        ],
      ),
    );
    expect(find.textContaining('Handler is off'), findsNothing);
    expect(find.text('Hard reset'), findsOneWidget);
    expect(find.text('stashed 3 files'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a quick-choice escalation becomes a card whose tap answers', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:status', armedStatusJson());
    await pumpDelivery(tester);
    t.emit('handler:escalation', escalationJson(choices: choicesJson()));
    await pumpDelivery(tester);

    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    // Rendered beside the label, not behind it: a one-tap the user cannot read
    // is one they cannot refuse.
    expect(find.text(approveText), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await pumpDelivery(tester);

    final sent = t.sent.where((m) => m['type'] == 'terminal:input').toList();
    expect(sent, hasLength(1));
    expect(sent.single['terminalId'], 't1');
    expect(sent.single['data'], '$approveText\r');
    // The answered row leaves with its card.
    expect(find.text('Reject'), findsNothing);
  });

  testWidgets('a replayed escalation is as one-tappable as a pushed one', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit(
      'handler:status',
      armedStatusJson(
        escalations: [
          {
            'escalationId': 'e9',
            'question': 'bun or vitest?',
            'reasoning': 'Affects CI wiring.',
            'draftReply': 'use bun',
            'urgency': 'high',
            'at': 1,
            'choices': choicesJson(),
          },
        ],
      ),
    );
    await pumpDelivery(tester);

    await tester.tap(find.text('Reject'));
    await pumpDelivery(tester);

    final sent = t.sent.where((m) => m['type'] == 'terminal:input').toList();
    expect(sent, hasLength(1));
    expect(sent.single['data'], '$rejectText\r');
  });

  testWidgets(
    'a status frame in flight when the answer went out cannot re-arm the tap',
    (tester) async {
      // Status is emitted twice per handler event on any session in the project,
      // so the bridge routinely has one computed before an answer reaches it. The
      // screen rebuilds its rows wholesale from that frame — the row may come
      // back, the one-tap must not.
      final t = await pumpLiveHandlerScreen(tester);
      final replay = armedStatusJson(
        escalations: [
          {
            'escalationId': 'e9',
            'question': 'bun or vitest?',
            'reasoning': 'Affects CI wiring.',
            'draftReply': 'use bun',
            'urgency': 'high',
            'at': 1,
            'choices': choicesJson(),
          },
        ],
      );
      t.emit('handler:status', replay);
      await pumpDelivery(tester);

      await tester.tap(find.text('Approve'));
      await pumpDelivery(tester);
      expect(t.sent.where((m) => m['type'] == 'terminal:input'), hasLength(1));

      t.emit('handler:status', replay);
      await pumpDelivery(tester);

      expect(find.byType(HandlerDecisionCard), findsNothing);
      expect(find.text('Approve'), findsNothing);
      // The question is still there and still answerable — only the one-tap left.
      expect(find.text('bun or vitest?'), findsOneWidget);
      await tester.tap(find.text('bun or vitest?'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
    },
  );

  testWidgets('two taps on one choice put a single answer on the wire', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:status', armedStatusJson());
    await pumpDelivery(tester);
    t.emit('handler:escalation', escalationJson(choices: choicesJson()));
    await pumpDelivery(tester);

    // No pump between them: the card the second tap hits is the one built
    // before the first, so the disabled repaint cannot be what stops it.
    await tester.tap(find.text('Approve'));
    await tester.tap(find.text('Approve'));
    await pumpDelivery(tester);

    expect(t.sent.where((m) => m['type'] == 'terminal:input'), hasLength(1));
  });

  testWidgets('a card still reaches free text, and it lands on the wire', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:status', armedStatusJson());
    await pumpDelivery(tester);
    t.emit('handler:escalation', escalationJson(choices: choicesJson()));
    await pumpDelivery(tester);

    await tester.tap(find.text(handlerCustomReplyLabel));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'neither, use jest');
    await tester.tap(find.text('Approve & send'));
    await tester.pumpAndSettle();

    final sent = t.sent.where((m) => m['type'] == 'terminal:input').toList();
    expect(sent, hasLength(1));
    expect(sent.single['data'], 'neither, use jest\r');
  });

  // The defect this screen was rebuilt for: six different left edges on one
  // scrolling list, three of them inside the "Needs you" section alone. Every
  // row now reserves the same leading slot, so a shield appearing on one row
  // cannot shift the title of the row beneath it.
  testWidgets(
    'every row title shares one left edge, whatever glyph it carries',
    (tester) async {
      const plain = HandlerEscalation(
        escalationId: 'e1',
        terminalId: 't1',
        question: 'plain question',
        reasoning: 'r',
        draftReply: 'd',
        urgency: 'normal',
        at: 1,
      );
      const floored = HandlerEscalation(
        escalationId: 'e2',
        terminalId: 't1',
        question: 'floored question',
        reasoning: 'r',
        draftReply: 'd',
        urgency: 'high',
        at: 2,
        floorRule: 'no force push',
      );
      await pumpHandlerScreen(
        tester,
        stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
          escalations: const [plain, floored],
          snapshots: const [
            HandlerSnapshot(
              snapshotId: 's1',
              terminalId: 't1',
              at: 1,
              action: 'force_push',
              trigger: 'git push --force',
              summary: 'pre-push SHA abc1234',
              state: 'available',
            ),
          ],
          activity: const [
            HandlerActivityRecord(
              recordId: 'r1',
              at: 1,
              terminalId: 't1',
              decision: 'armed',
              reason: '',
            ),
          ],
        ),
      );

      double leftOf(String text) => tester.getTopLeft(find.text(text)).dx;
      // The session card's Armed chip carries this word too, so the activity row
      // is addressed through the AbListRow only it is built from.
      double leftOfRow(String text) => tester
          .getTopLeft(
            find.descendant(
              of: find.byType(AbListRow),
              matching: find.text(text),
            ),
          )
          .dx;
      // 'summary' is the session goal from sessionState().
      final edges = {
        leftOf('plain question'), // no leading glyph
        leftOf('floored question'), // safety-floor shield
        leftOf('Force push'), // revert glyph
        leftOfRow('Armed'), // activity-kind glyph
        leftOf('summary'), // session card, empty rail
      };
      expect(edges, hasLength(1), reason: 'ragged left edges: $edges');
      debugDefaultTargetPlatformOverride = null;
    },
  );

  // An escalation question is the thing being decided. Clipped to one line by
  // AbListRow's default it was a decision taken without its subject.
  testWidgets('a long escalation question wraps instead of ellipsizing', (
    tester,
  ) async {
    const short = 'short?';
    const long =
        'The migration drops the legacy sessions table and rewrites every '
        'foreign key that pointed at it, which cannot be rolled back once the '
        'deploy has run against production — should I go ahead with it now?';
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
        escalations: const [
          HandlerEscalation(
            escalationId: 'e1',
            terminalId: 't1',
            question: short,
            reasoning: 'r',
            draftReply: 'd',
            urgency: 'normal',
            at: 1,
          ),
          HandlerEscalation(
            escalationId: 'e2',
            terminalId: 't1',
            question: long,
            reasoning: 'r',
            draftReply: 'd',
            urgency: 'normal',
            at: 2,
          ),
        ],
      ),
    );

    expect(
      tester.getSize(find.text(long)).height,
      greaterThan(tester.getSize(find.text(short)).height),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  // The rail exists to put one glyph column beside the titles. Centred against
  // a wrapped question it drifted to the middle of the block — level with the
  // reasoning, not with the thing it qualifies.
  testWidgets('the safety-floor glyph stays beside a wrapped question', (
    tester,
  ) async {
    const long =
        'The migration drops the legacy sessions table and rewrites every '
        'foreign key that pointed at it, which cannot be rolled back once the '
        'deploy has run against production — should I go ahead with it now?';
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}).copyWith(
        escalations: const [
          HandlerEscalation(
            escalationId: 'e1',
            terminalId: 't1',
            question: long,
            reasoning: 'the working tree diverged after the rebase',
            draftReply: 'd',
            urgency: 'high',
            floorRule: 'no force push',
            at: 1,
          ),
        ],
      ),
    );

    final title = tester.getRect(find.text(long));
    final shield = tester.getRect(
      find.descendant(
        of: find.byType(AbListRow),
        matching: find.byType(AbIcon),
      ),
    );
    expect(shield.top, lessThan(title.center.dy));
    debugDefaultTargetPlatformOverride = null;
  });

  // `status` is parsed as free text, so a word this column was never sized for
  // is a normal thing to receive — and breaking it across three lines inside a
  // fixed box grows every row in the backlog.
  testWidgets('an unfamiliar backlog status widens rather than wrapping', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': HandlerSessionState(
            terminalId: 't1',
            notifyOnly: false,
            runState: HandlerRunState.watching,
            pendingEscalations: 0,
            armedAt: 1,
            goal: 'g',
            backlog: const [
              HandlerInstructionItem(
                id: 'i1',
                text: 'run the tests',
                status: 'done',
                createdAt: 1,
              ),
              HandlerInstructionItem(
                id: 'i2',
                text: 'open a PR',
                status: 'awaiting_review',
                createdAt: 2,
              ),
            ],
            escalations: const [],
          ),
        },
      ),
    );

    final short = tester.getSize(find.text('done'));
    final unfamiliar = tester.getSize(find.text('awaiting_review'));
    expect(unfamiliar.height, short.height);
    expect(unfamiliar.width, greaterThan(short.width));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('an escalation without choices keeps the free-text row', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:status', armedStatusJson());
    await pumpDelivery(tester);
    t.emit('handler:escalation', escalationJson());
    await pumpDelivery(tester);

    expect(find.byType(HandlerDecisionCard), findsNothing);
    expect(find.text(handlerCustomReplyLabel), findsNothing);

    await tester.tap(find.text('bun or vitest?'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve & send'));
    await tester.pumpAndSettle();

    final sent = t.sent.where((m) => m['type'] == 'terminal:input').toList();
    expect(sent, hasLength(1));
    expect(sent.single['data'], 'use bun\r');
  });

  // The run state used to live only in the title-bar pill, which is nowhere
  // near this panel — so the tab named Handler opened without ever saying what
  // Handler was doing.
  testWidgets('the card states the run state above the goal', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(sessions: {'t1': sessionState('t1')}),
    );

    expect(find.text('Watching'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Watching')).dy,
      lessThan(tester.getTopLeft(find.text('summary')).dy),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a paused session says why it stopped and when it returns', (
    tester,
  ) async {
    // A live deadline, so this exercises the wake-time arm rather than the
    // elapsed one. The exact rendering of both is pinned by the unit test
    // below; here it only has to reach the card.
    final until = DateTime.now().add(const Duration(hours: 1));
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': HandlerSessionState(
            terminalId: 't1',
            notifyOnly: false,
            runState: HandlerRunState.parked,
            pendingEscalations: 0,
            armedAt: 1,
            goal: 'ship it',
            backlog: const [],
            escalations: const [],
            parkKind: 'limit',
            parkedUntil: until.millisecondsSinceEpoch,
          ),
        },
      ),
    );

    // "Paused", never the wire's "parked" — one vocabulary with the pill.
    expect(find.text('Paused'), findsOneWidget);
    expect(find.textContaining('rate limit · resumes '), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  // A notify-only session never acts on the user's behalf. Nothing else on the
  // screen distinguishes it from one that does.
  testWidgets('a notify-only session says so', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': HandlerSessionState(
            terminalId: 't1',
            notifyOnly: true,
            runState: HandlerRunState.watching,
            pendingEscalations: 0,
            armedAt: 1,
            goal: 'ship it',
            backlog: const [],
            escalations: const [],
          ),
        },
      ),
    );

    expect(find.text('NOTIFY ONLY'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  // `queued` is the status of every item on a fresh backlog, so printing it
  // fills the column with one repeated value and leaves the states that DID
  // change nothing to stand out against.
  testWidgets('only a status that changed gets a word', (tester) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': HandlerSessionState(
            terminalId: 't1',
            notifyOnly: false,
            runState: HandlerRunState.watching,
            pendingEscalations: 0,
            armedAt: 1,
            goal: 'ship it',
            backlog: const [
              HandlerInstructionItem(
                id: 'i1',
                text: 'review latest changes',
                status: 'queued',
                createdAt: 1,
              ),
              HandlerInstructionItem(
                id: 'i2',
                text: 'open a PR',
                status: 'blocked',
                createdAt: 2,
              ),
            ],
            escalations: const [],
          ),
        },
      ),
    );

    expect(find.text('review latest changes'), findsOneWidget);
    expect(find.text('queued'), findsNothing);
    expect(find.text('blocked'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  // Disarming is one mis-tap away from a scrolling list, and the chip states
  // what IS ("Armed") — so the tap opens the menu and the menu does the work.
  testWidgets('the armed chip opens a menu rather than disarming', (
    tester,
  ) async {
    final t = await pumpLiveHandlerScreen(tester);
    t.emit('handler:status', armedStatusJson());
    await pumpDelivery(tester);

    List<Map<String, dynamic>> disarms() => t.sent
        .where((m) => m['type'] == 'handler:configure' && m['armed'] == false)
        .toList();

    await tester.tap(find.text('Armed'));
    await tester.pumpAndSettle();
    expect(disarms(), isEmpty);

    await tester.tap(find.text('Disarm Handler'));
    await tester.pumpAndSettle();

    expect(disarms(), hasLength(1));
    expect(disarms().single['terminalId'], 't1');
  });

  // The card's status line is the one row on this screen with fixed widgets at
  // both ends. It has to survive the narrowest thing that mounts it: a phone,
  // and a desktop context panel dragged to its minimum ratio.
  testWidgets('the session card fits the narrowest panel that mounts it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          for (final id in ['t1', 't2'])
            id: HandlerSessionState(
              terminalId: id,
              // Notify-only and needsYou together: the longest run-state word
              // and the one extra marker, on the same line.
              notifyOnly: true,
              runState: HandlerRunState.needsYou,
              pendingEscalations: 1,
              armedAt: 1,
              goal: 'ship it',
              backlog: const [],
              escalations: const [],
            ),
        },
      ),
    );

    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  // A deadline already behind us means the resume is in flight, not that the
  // session is overdue — the rule handlerPaStatusLabel follows, so the bar and
  // the card never disagree about one park.
  test('a park note past its deadline promises a resume, not a time', () {
    final session = HandlerSessionState(
      terminalId: 't1',
      notifyOnly: false,
      runState: HandlerRunState.parked,
      pendingEscalations: 0,
      armedAt: 1,
      goal: 'ship it',
      backlog: const [],
      escalations: const [],
      parkKind: 'limit',
      parkedUntil: DateTime(2026, 8, 3, 14).millisecondsSinceEpoch,
    );

    expect(
      handlerParkNote(session, now: DateTime(2026, 8, 3, 15)),
      'rate limit · resuming',
    );
    expect(
      handlerParkNote(session, now: DateTime(2026, 8, 3, 13)),
      'rate limit · resumes 14:00',
    );
  });

  testWidgets('an unwatchable armed session says so on its row', (
    tester,
  ) async {
    await pumpHandlerScreen(
      tester,
      stateWith(
        sessions: {
          't1': sessionState(
            't1',
            observability: HandlerObservability.unsupported,
          ),
        },
      ),
    );
    expect(find.textContaining('Not watched'), findsOneWidget);
    expect(find.text('ESCALATE ONLY'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'an escalate-only session reads differently from an unwatchable one',
    (tester) async {
      // Two distinct facts: this one IS watched and merely has no judge to answer
      // with. Rendering them the same would hide which one the user is looking at.
      await pumpHandlerScreen(
        tester,
        stateWith(
          sessions: {
            't1': sessionState(
              't1',
              observability: HandlerObservability.escalateOnly,
            ),
          },
        ),
      );
      expect(find.text('ESCALATE ONLY'), findsOneWidget);
      expect(find.textContaining('Not watched'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'a session with no reported observability is marked neither way',
    (tester) async {
      await pumpHandlerScreen(
        tester,
        stateWith(sessions: {'t1': sessionState('t1')}),
      );
      expect(find.textContaining('Not watched'), findsNothing);
      expect(find.text('ESCALATE ONLY'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'a guard_blocked row renders the refused text and dismisses it on the wire',
    (tester) async {
      // The row exists because a guard refused this exact text, so the card has
      // to SHOW it — a rejection the user cannot read is one they cannot judge —
      // and offer the one control that retires it.
      final t = await pumpLiveHandlerScreen(tester);
      t.emit('handler:status', armedStatusJson(escalations: [
        {
          'escalationId': 'b1',
          'question': 'Handler did not send its reply',
          'reasoning': 'slash command /code-review is not in this catalog',
          'draftReply': '/code-review --fix',
          'urgency': 'normal',
          'at': 1,
          'kind': 'guard_blocked',
        },
      ]));
      await pumpDelivery(tester);

      expect(find.byType(HandlerBlockedActionCard), findsOneWidget);
      expect(find.text('/code-review --fix'), findsOneWidget);

      await tester.tap(find.text(handlerDismissLabel));
      await tester.pump();

      final sent = t.sent.where((m) => m['type'] == 'handler:dismiss').toList();
      expect(sent, hasLength(1));
      expect(sent.single['projectId'], 'p');
      expect(sent.single['terminalId'], 't1');
      expect(sent.single['escalationId'], 'b1');
    },
  );
}
