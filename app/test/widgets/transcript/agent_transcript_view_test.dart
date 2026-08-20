// Integration-shaped test for the transcript shell: it renders the real
// `deriveRows` pipeline over an `AgentSessionState` fixture (no transport) to
// prove row widgets wire up end-to-end, plus the empty-state fallback.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/agent_event.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/services/agent_session_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/agent_transcript_view.dart';
import 'package:antgrid/widgets/transcript/composer/rich_composer.dart';
import 'package:antgrid/widgets/transcript/composer_selectors.dart';
import 'package:antgrid/widgets/transcript/context_meter.dart';
import 'package:antgrid/widgets/transcript/pending_prompt_panel.dart';
import 'package:antgrid/widgets/transcript/rows/message_row.dart';
import 'package:antgrid/widgets/transcript/rows/tool_call_card.dart';
import 'package:antgrid/widgets/transcript/rows/turn_fold_row.dart';
import 'package:antgrid/widgets/transcript/rows/working_row.dart';
import 'package:antgrid/widgets/transcript/slash_suggestions.dart';
import 'package:antgrid/design/widgets/ab_composer_send_button.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/widgets/transcript/file_mention_suggestions.dart';
import 'package:flutter/services.dart';
import '../../helpers/prefs_test_mock.dart';

const _sessionId = 'sess-1';

const _capsFixture = AgentCapabilities(
  sessionId: _sessionId,
  commands: [
    AgentCapabilityCommand(id: 'builtin:compact', name: 'compact'),
    AgentCapabilityCommand(id: 'cmd:review', name: 'review'),
  ],
  models: [
    AgentCapabilityModel(id: 'gpt-5.2', name: 'GPT-5.2'),
    AgentCapabilityModel(id: 'gpt-5.2-mini', name: 'GPT-5.2 Mini'),
  ],
  currentModelId: 'gpt-5.2',
);

Future<(FakeAgentTransport, ProjectSession, AgentSessionService)>
_serviceFixture() async {
  final t = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'p',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await t.dispose(),
  );
  return (t, session, AgentSessionService.fromSession(session));
}

Future<FakeAgentTransport> _pumpWithService(
  WidgetTester tester,
  AgentSessionState state, {
  List<Override> extraOverrides = const [],
}) async {
  final (t, session, svc) = await _serviceFixture();
  final container = ProviderContainer(
    overrides: [
      agentSessionStateProvider.overrideWith(
        (ref, sessionId) => Stream.value(state),
      ),
      // serviceWhenReady gates on a focused id AND a resolved session
      // BEFORE reading the service provider — without these two overrides
      // every outbound send in the view is a silent no-op and the
      // send-asserting tests below can never pass.
      selectedRegistrationIdProvider.overrideWithValue('p'),
      projectSessionProvider.overrideWith((ref, id) async => session),
      agentSessionServiceProvider.overrideWithValue(svc),
      ...extraOverrides,
    ],
  );
  addTearDown(container.dispose);
  // Nothing in the widget tree watches projectSessionProvider during build
  // (only inside tap handlers via serviceWhenReady) — pre-resolve it here so
  // the FIRST watch, which happens synchronously inside a Send/pill tap, sees
  // AsyncData instead of one frame of AsyncLoading with no way to re-pump.
  await container.read(projectSessionProvider('p').future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: AgentTranscriptView(sessionId: _sessionId)),
      ),
    ),
  );
  await tester.pump();
  return t;
}

AgentItem _item(String id, String kind, {String? role, String? text}) =>
    AgentItem(itemId: id, kind: kind, role: role, text: text);

// Many settled turns so the ListView overflows a small test surface —
// needed to get maxScrollExtent > 0 for the jump-to-latest pill test.
AgentSessionState _tallState({int turnCount = 40}) => AgentSessionState(
  turns: [
    for (var i = 0; i < turnCount; i++)
      AgentTurn(
        turnId: 't$i',
        items: [
          _item('u$i', 'message', role: 'user', text: 'prompt number $i'),
          _item('m$i', 'message', role: 'assistant', text: 'reply number $i'),
        ],
        stopReason: 'end_turn',
        startedAt: DateTime(2026, 1, 1, 0, i, 0),
        endedAt: DateTime(2026, 1, 1, 0, i, 30),
      ),
  ],
);

AgentSessionState _twoTurnState() => AgentSessionState(
  turns: [
    // Settled past turn: folds into a TurnFoldRow (keeps the user prompt +
    // trailing assistant answer, hides the tool call in between).
    AgentTurn(
      turnId: 't1',
      items: [
        _item('u1', 'message', role: 'user', text: 'do the thing'),
        _item('c1', 'tool_call'),
        _item('m1', 'message', role: 'assistant', text: 'done'),
      ],
      stopReason: 'end_turn',
      startedAt: DateTime(2026, 1, 1, 0, 0, 0),
      endedAt: DateTime(2026, 1, 1, 0, 1, 0),
    ),
    // Active unsettled turn: renders fully + a trailing WorkingRow.
    AgentTurn(
      turnId: 't2',
      items: [
        _item('u2', 'message', role: 'user', text: 'now this'),
        AgentItem(
          itemId: 'c2',
          kind: 'tool_call',
          title: 'grep',
          status: 'running',
        ),
      ],
      startedAt: DateTime(2026, 1, 1, 0, 2, 0),
    ),
  ],
);

// Fleather isn't an EditableText, so tester.enterText doesn't apply — push
// text straight through the controller instead. The explicit `selection:`
// mirrors what enterText does (caret at the end); the slash-suggestion tests
// depend on that (suggestions only show with a valid caret inside the
// command token).
Future<void> _typeIntoComposer(WidgetTester tester, String text) async {
  final composer = tester.widget<RichComposer>(find.byType(RichComposer));
  composer.controller.fleather.replaceText(
    0,
    0,
    text,
    selection: TextSelection.collapsed(offset: text.length),
  );
  await tester.pump();
  await _settleComposerHistory(tester);
}

/// Past Fleather's 500ms history throttle. The composer controller is cached
/// per session now, so unmounting the view no longer disposes it — and the
/// throttle timer that disposal used to cancel is still armed at teardown,
/// which flutter_test fails as a pending timer. Nothing in the composer
/// debounces, so settling it moves nothing any test asserts on.
Future<void> _settleComposerHistory(WidgetTester tester) =>
    tester.pump(const Duration(milliseconds: 600));

/// Unmounts the tree the way every test here ends, then settles the throttle
/// re-armed by any edit made after [_typeIntoComposer] — see
/// [_settleComposerHistory].
Future<void> _disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _settleComposerHistory(tester);
}

Future<void> _pump(WidgetTester tester, AgentSessionState state) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        agentSessionStateProvider.overrideWith(
          (ref, sessionId) => Stream.value(state),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: AgentTranscriptView(sessionId: _sessionId)),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  testWidgets(
    'renders folded past turn, active turn messages, working row and tool card',
    (tester) async {
      await _pump(tester, _twoTurnState());
      await tester.pump();

      expect(find.byType(TurnFoldRow), findsOneWidget);
      expect(find.byType(MessageRow), findsAtLeastNWidgets(2));
      expect(find.byType(WorkingRow), findsOneWidget);
      expect(find.byType(ToolCallCard), findsOneWidget);

      await _disposeTree(tester);
    },
  );

  testWidgets(
    'empty state shows centered muted prompt and no rows, composer still visible',
    (tester) async {
      await _pump(tester, const AgentSessionState());
      await tester.pump();

      expect(find.text('Send a message to start'), findsOneWidget);
      expect(find.byType(MessageRow), findsNothing);
      expect(find.byType(ToolCallCard), findsNothing);
      // Composer is still present.
      expect(find.byType(ComposerSendButton), findsOneWidget);

      await _disposeTree(tester);
    },
  );

  testWidgets(
    'loading state shows spinner (not the empty-state prompt), composer still visible',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            agentSessionStateProvider.overrideWith(
              (ref, sessionId) => const Stream<AgentSessionState>.empty(),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: AgentTranscriptView(sessionId: _sessionId)),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(AbLoading), findsOneWidget);
      expect(find.text('Send a message to start'), findsNothing);
      expect(find.byType(ComposerSendButton), findsOneWidget);

      await _disposeTree(tester);
    },
  );

  testWidgets(
    'hydrating state shows spinner before an empty transcript is known-empty',
    (tester) async {
      await _pump(tester, const AgentSessionState(loading: true));
      await tester.pump();

      expect(find.byType(AbLoading), findsOneWidget);
      expect(find.text('Send a message to start'), findsNothing);
      expect(find.byType(ComposerSendButton), findsOneWidget);

      await _disposeTree(tester);
    },
  );

  testWidgets(
    'shows an inline retry row when hydration failed and there are no turns',
    (tester) async {
      await _pump(tester, const AgentSessionState(hydrationFailed: true));
      await tester.pump();

      expect(find.text("Couldn't load earlier messages"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Send a message to start'), findsNothing);

      await _disposeTree(tester);
    },
  );

  testWidgets(
    'mounting for the active chat session with no turns hydrates it',
    (tester) async {
      // The single chokepoint: the view is keyed per active session, so its
      // initState is where EVERY activation path (drill-in, cross-project open,
      // nav restore) converges. Mounting it must pull the transcript without any
      // external hydrateAttachedChatIfNeeded call at the activation site.
      const entry = SessionEntry(
        id: _sessionId,
        name: 'Chat',
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: true,
        mode: 'chat',
        agentSessionId: 'agent-sess-1',
      );
      final t = await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: [activeSessionProvider.overrideWithValue(entry)],
      );
      t.requestHandler = (method, params) => {'frames': <dynamic>[]};
      // Let the post-frame hydration callback + its async pull run.
      await tester.pump();
      await tester.pump();

      expect(
        t.requests.where((r) => r.method == 'session.transcriptSnapshot'),
        isNotEmpty,
      );

      await _disposeTree(tester);
    },
  );

  testWidgets('tapping the retry row calls hydrateIfNeeded for this session', (
    tester,
  ) async {
    final t = await _pumpWithService(
      tester,
      const AgentSessionState(hydrationFailed: true),
    );
    t.requestHandler = (method, params) => {'frames': <dynamic>[]};

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(t.requests, isNotEmpty);
    expect(t.requests.last.method, 'session.transcriptSnapshot');
    expect(t.requests.last.params, {'sessionId': _sessionId});

    await _disposeTree(tester);
  });

  testWidgets('tapping a user message revert button sends revert action', (
    tester,
  ) async {
    final t = await _pumpWithService(
      tester,
      AgentSessionState(
        turns: [
          AgentTurn(
            turnId: 't1',
            items: [
              const AgentItem(
                itemId: 'u1',
                kind: 'message',
                role: 'user',
                text: 'undo from here',
                revertMessageId: 'm1',
                revertPartId: 'p1',
              ),
            ],
            stopReason: 'end_turn',
          ),
        ],
      ),
    );

    await tester.tap(find.byTooltip('Revert conversation'));
    await tester.pump();

    final msg = t.sent.lastWhere((m) => m['type'] == 'agent:session-action');
    expect(msg['action'], 'revert');
    expect(msg['turnId'], 't1');
    expect(msg['itemId'], 'u1');
    expect(msg['messageId'], 'm1');
    expect(msg['partId'], 'p1');

    await _disposeTree(tester);
  });

  testWidgets('tapping a prompt marker focuses the pinned panel field', (
    tester,
  ) async {
    const state = AgentSessionState(
      pendingQuestions: [
        AgentQuestion(
          sessionId: _sessionId,
          questionId: 'q1',
          kind: 'text',
          prompt: 'What is your name?',
          options: [],
          isSecret: false,
        ),
      ],
    );
    await _pump(tester, state);
    await tester.pump();

    final panelField = find.descendant(
      of: find.byType(PendingPromptPanel),
      matching: find.byType(EditableText),
    );
    expect(panelField, findsOneWidget);
    expect(tester.widget<EditableText>(panelField).focusNode.hasFocus, isFalse);

    await tester.tap(find.textContaining('waiting for'));
    await tester.pump();

    expect(tester.widget<EditableText>(panelField).focusNode.hasFocus, isTrue);

    await _disposeTree(tester);
  });

  group('jump to latest pill', () {
    testWidgets('appears when scrolled up and jumps to bottom on tap', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await _pump(tester, _tallState());
      await tester.pump();

      expect(find.text('jump to latest'), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pump();

      expect(find.text('jump to latest'), findsOneWidget);

      await tester.tap(find.text('jump to latest'));
      await tester.pumpAndSettle();

      expect(find.text('jump to latest'), findsNothing);
      final listView = tester.widget<ListView>(find.byType(ListView));
      final controller = listView.controller!;
      expect(controller.offset, controller.position.maxScrollExtent);

      await _disposeTree(tester);
    });
  });

  group('composer capabilities', () {
    const stateWithCaps = AgentSessionState(capabilities: _capsFixture);

    testWidgets('places context meter between upload and selector controls', (
      tester,
    ) async {
      const state = AgentSessionState(
        capabilities: _capsFixture,
        usage: AgentUsage(
          total: AgentTokenUsage(totalTokens: 6000),
          contextWindow: 1000000,
        ),
      );
      await _pumpWithService(tester, state);

      final upload = find.ancestor(
        of: find.byTooltip('Attach file'),
        matching: find.byType(AbIconButton),
      );
      final meter = find.byType(ContextMeter);
      final selectors = find.byType(ComposerSelectors);

      expect(
        tester.getBottomRight(upload).dx,
        lessThanOrEqualTo(tester.getTopLeft(meter).dx),
      );
      expect(
        tester.getBottomRight(meter).dx,
        lessThanOrEqualTo(tester.getTopLeft(selectors).dx),
      );

      await _disposeTree(tester);
    });

    testWidgets('typing /re filters the suggestion panel', (tester) async {
      await _pumpWithService(tester, stateWithCaps);
      await _typeIntoComposer(tester, '/re');
      expect(find.text('/review'), findsOneWidget);
      expect(find.text('/compact'), findsNothing);
      await _disposeTree(tester);
    });

    testWidgets('keeps an unsent draft when the chat view remounts', (
      tester,
    ) async {
      final (_, session, svc) = await _serviceFixture();
      final container = ProviderContainer(
        overrides: [
          agentSessionStateProvider.overrideWith(
            (ref, sessionId) => Stream.value(const AgentSessionState()),
          ),
          selectedRegistrationIdProvider.overrideWithValue('p'),
          projectSessionProvider.overrideWith((ref, id) async => session),
          agentSessionServiceProvider.overrideWithValue(svc),
        ],
      );
      addTearDown(container.dispose);
      await container.read(projectSessionProvider('p').future);

      Widget view() => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: AgentTranscriptView(sessionId: _sessionId)),
        ),
      );

      await tester.pumpWidget(view());
      await tester.pump();
      await _typeIntoComposer(tester, 'keep this draft');

      await _disposeTree(tester);
      await tester.pump();
      await tester.pumpWidget(view());
      await tester.pump();

      final composer = tester.widget<RichComposer>(find.byType(RichComposer));
      expect(
        composer.controller.fleather.document.toPlainText(),
        'keep this draft\n',
      );
    });

    testWidgets('tapping a suggestion completes the token', (tester) async {
      await _pumpWithService(tester, stateWithCaps);
      await _typeIntoComposer(tester, '/re');
      await tester.tap(find.text('/review'));
      await tester.pump();
      expect(find.byType(SlashSuggestions), findsOneWidget);
      // Fleather renders line content via bare RichText (not Text/EditableText),
      // so find.text can't see it — read the completed token off the document
      // instead, matching composer_controller_test's convention.
      final composer = tester.widget<RichComposer>(find.byType(RichComposer));
      expect(composer.controller.fleather.document.toPlainText(), '/review \n');
      await _disposeTree(tester);
    });

    testWidgets('submitting /review args sends commandId + stripped text', (
      tester,
    ) async {
      final t = await _pumpWithService(tester, stateWithCaps);
      await _typeIntoComposer(tester, '/review src/');
      await tester.tap(find.byType(ComposerSendButton));
      await tester.pump();
      final prompt = t.sent.lastWhere((m) => m['type'] == 'agent:prompt');
      expect(prompt['commandId'], 'cmd:review');
      expect(prompt['text'], 'src/');
      expect(
        tester
            .widget<RichComposer>(find.byType(RichComposer))
            .controller
            .isEmpty,
        isTrue,
      );
      await _disposeTree(tester);
    });

    testWidgets('unknown /token submits verbatim without commandId', (
      tester,
    ) async {
      final t = await _pumpWithService(tester, stateWithCaps);
      await _typeIntoComposer(tester, '/nonesuch hi');
      await tester.tap(find.byType(ComposerSendButton));
      await tester.pump();
      final prompt = t.sent.lastWhere((m) => m['type'] == 'agent:prompt');
      expect(prompt.containsKey('commandId'), isFalse);
      expect(prompt['text'], '/nonesuch hi');
      await _disposeTree(tester);
    });

    testWidgets('model pill opens a menu and picking sends set-config', (
      tester,
    ) async {
      final t = await _pumpWithService(tester, stateWithCaps);
      expect(find.byType(ComposerSelectors), findsOneWidget);
      await tester.tap(find.text('GPT-5.2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('GPT-5.2 Mini'));
      await tester.pumpAndSettle();
      final msg = t.sent.lastWhere((m) => m['type'] == 'agent:set-config');
      expect(msg['key'], 'model');
      expect(msg['value'], 'gpt-5.2-mini');
      await _disposeTree(tester);
    });
  });

  group('file mentions', () {
    FileNode file(String path) => FileNode(
      name: path.split('/').last,
      path: path,
      type: FileNodeType.file,
    );
    final treeRoot = FileNode(
      name: '',
      path: '',
      type: FileNodeType.directory,
      children: [
        file('README.md'),
        FileNode(
          name: 'lib',
          path: 'lib',
          type: FileNodeType.directory,
          children: [
            file('lib/main.dart'),
            FileNode(
              name: 'src',
              path: 'lib/src',
              type: FileNodeType.directory,
              children: [file('lib/src/util.dart')],
            ),
          ],
        ),
      ],
    );
    final treeOverrides = <Override>[
      fileTreeStateProvider.overrideWith(
        (ref) => Stream.value(FileTreeState(projectId: 'p', root: treeRoot)),
      ),
    ];

    String composerText(WidgetTester tester) => tester
        .widget<RichComposer>(find.byType(RichComposer))
        .controller
        .fleather
        .document
        .toPlainText();

    testWidgets('typing @ opens a files-first shallow-first browse list', (
      tester,
    ) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, '@');
      expect(find.byType(FileMentionSuggestions), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.text('lib/'), findsOneWidget); // dir marker
      await _disposeTree(tester);
    });

    testWidgets('typing @ut filters to matching paths', (tester) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, '@ut');
      expect(find.text('lib/src/util.dart'), findsOneWidget);
      expect(find.text('README.md'), findsNothing);
      await _disposeTree(tester);
    });

    testWidgets('tapping a file row inserts the mention', (tester) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, '@ma');
      await tester.tap(find.text('lib/main.dart'));
      await tester.pump();
      expect(composerText(tester), '@lib/main.dart \n');
      expect(find.text('lib/main.dart'), findsNothing); // panel closed
      await _disposeTree(tester);
    });

    testWidgets('tapping a dir row inserts a trailing-slash mention', (
      tester,
    ) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, '@li');
      await tester.tap(find.text('lib/'));
      await tester.pump();
      expect(composerText(tester), '@lib/ \n');
      await _disposeTree(tester);
    });

    testWidgets('arrow down + enter accepts the second entry; Esc closes '
        'and an edit reopens', (tester) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, '@');
      // Key events route through the composer FocusNode's onKeyEvent — it
      // must actually hold focus for sendKeyEvent to reach it.
      final composer = tester.widget<RichComposer>(find.byType(RichComposer));
      composer.focusNode!.requestFocus();
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // Browse order: README.md, lib/main.dart, lib/src/util.dart, dirs…
      expect(composerText(tester), '@lib/main.dart \n');

      // Reopen on the completed mention's tail? No token (space closed it) —
      // type a fresh @, Esc-dismiss, then edit to re-arm.
      composer.controller.fleather.replaceText(
        '@lib/main.dart '.length,
        0,
        '@',
        selection: TextSelection.collapsed(offset: '@lib/main.dart @'.length),
      );
      await tester.pump();
      expect(find.text('README.md'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('README.md'), findsNothing);

      composer.controller.fleather.replaceText(
        '@lib/main.dart @'.length,
        0,
        'r',
        selection: TextSelection.collapsed(offset: '@lib/main.dart @r'.length),
      );
      await tester.pump();
      expect(find.text('README.md'), findsOneWidget);
      await _disposeTree(tester);
    });

    testWidgets('@ after a slash command shows mentions, not slash rows', (
      tester,
    ) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(capabilities: _capsFixture),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, '/review @ut');
      expect(find.text('lib/src/util.dart'), findsOneWidget);
      expect(find.text('/review'), findsNothing);
      await _disposeTree(tester);
    });

    testWidgets('email-like a@b shows no panel', (tester) async {
      await _pumpWithService(
        tester,
        const AgentSessionState(),
        extraOverrides: treeOverrides,
      );
      await _typeIntoComposer(tester, 'a@b');
      expect(find.text('README.md'), findsNothing);
      expect(find.text('lib/main.dart'), findsNothing);
      await _disposeTree(tester);
    });
  });
}
