import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/widgets/ab_cross_fade.dart';
import 'package:antgrid/design/widgets/ab_switch.dart';
import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/models/agent_descriptor.dart';
import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/providers/agent_catalog.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/new_session_start.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/services/sessions_service.dart'
    show SessionOperationException;
import 'package:antgrid/utils/platform_utils.dart';
import 'package:antgrid/widgets/ab_status_helpers.dart' show friendlyErrorCopy;
import 'package:antgrid/widgets/new_session/branch_menu.dart';
import 'package:antgrid/widgets/new_session/environment_menu.dart';
import 'package:antgrid/widgets/new_session/new_session_composer.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';
import 'package:antgrid/widgets/new_session/project_menu.dart';

// Fabricated sources follow the pattern used in test/widgets/project_menu_test.dart
// and test/widgets/environment_menu_test.dart: pickerSourcesProvider is a pure
// Provider<List<PickerSource>>, so it can be overridden with a literal list.
const _project = PickerProject(
  id: 'p-my-repo',
  name: 'my-repo',
  detail: '/home/me/my-repo',
  isLocal: true,
);

const _localSource = PickerSource(
  id: 'local',
  label: 'Local',
  isLocal: true,
  projects: [_project],
);

/// A re-emittable driver for the chat-capability re-emission regression test.
/// The other tests override newSessionChatCapableToolsProvider with a
/// single-shot Future; this NotifierProvider lets a test push a fresh value
/// (a reference-distinct Set) to simulate a control-plane heartbeat / project
/// start-stop re-emitting the provider.
final _chatCapDriver =
    NotifierProvider<ValueController<Set<String>?>, Set<String>?>(
      () => ValueController(<String>{'claude-code'}),
    );

/// Mounts/unmounts the composer inside a single, persistent ProviderScope so a
/// mount → unmount → re-mount cycle keeps the SAME container — the setup the
/// autoDispose regression test needs (a fresh ProviderScope per pumpWidget
/// would drop the very provider state under test).
final _composerVisible = NotifierProvider<ValueController<bool>, bool>(
  () => ValueController(true),
);

/// A catalog notifier seeded with a fixed map, bypassing the disk hydration.
/// Stands in for "some bridge has already described these agents".
class _SeededCatalog extends AgentCatalogNotifier {
  _SeededCatalog(this.seed);

  final Map<String, AgentDescriptor> seed;

  @override
  Map<String, AgentDescriptor> build() => seed;
}

AgentDescriptor _descriptor(
  String tool,
  String label, {
  bool chatCapable = false,
  List<String> terminalApprovalPolicies = const ['default'],
  List<String> chatApprovalPolicies = const ['default'],
  String? approvalPolicyRisk,
}) => AgentDescriptor(
  tool: tool,
  label: label,
  chatCapable: chatCapable,
  judgeCapable: chatCapable,
  handlerTerminal: chatCapable,
  handlerChat: chatCapable,
  terminalApprovalPolicies: terminalApprovalPolicies,
  chatApprovalPolicies: chatApprovalPolicies,
  approvalPolicyRisk: approvalPolicyRisk,
);

/// The catalog a machine running today's bridge advertises, in registry order.
final _fullCatalog = <String, AgentDescriptor>{
  'claude-code': _descriptor('claude-code', 'Claude Code', chatCapable: true),
  'codex': _descriptor(
    'codex',
    'Codex',
    chatCapable: true,
    terminalApprovalPolicies: const ['default', 'bypass'],
    chatApprovalPolicies: const ['default', 'bypass'],
    approvalPolicyRisk: 'bypasses-approvals-and-sandbox',
  ),
  'opencode': _descriptor('opencode', 'opencode', chatCapable: true),
  'cursor-agent': _descriptor('cursor-agent', 'Cursor'),
  'github-copilot': _descriptor('github-copilot', 'Copilot'),
};

/// Base overrides every test needs: one local source, and detection/chat-
/// capability futures stubbed so the widget never touches a real host
/// controller. The agent catalog is seeded to what a current bridge advertises;
/// pass `catalog: const {}` for the older-bridge case where nothing has
/// described any agent. Callers append target/agent overrides on top.
List<Override> _baseOverrides({
  PickerProject? target,
  Map<String, String?> detected = const <String, String?>{},
  Set<String>? chatCapable,
  Map<String, AgentDescriptor>? catalog,
  bool worktreeSupported = false,
  String currentBranch = 'main',
  List<PickerSource> sources = const [_localSource],
}) {
  return [
    pickerSourcesProvider.overrideWithValue(sources),
    newSessionDetectedToolsProvider.overrideWith((ref) async => detected),
    newSessionChatCapableToolsProvider.overrideWith((ref) async => chatCapable),
    agentCatalogProvider.overrideWith(
      () => _SeededCatalog(catalog ?? _fullCatalog),
    ),
    newSessionBranchCatalogProvider.overrideWith(
      (ref) async => target == null
          ? null
          : GitBranchCatalog(
              isRepository: true,
              current: currentBranch,
              branches: ['main', 'dev', currentBranch],
              worktreeSessionsSupported: worktreeSupported,
            ),
    ),
    if (target != null)
      selectedTargetProjectProvider.overrideWith(() => ValueController(target)),
  ];
}

/// The mode dropdown shows only the current mode, so its trigger label IS
/// the selection. The label Text is the chip's first, ahead of the ALPHA badge.
String _selectedMode(WidgetTester tester) => tester
    .widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('new-session-mode-chip')),
            matching: find.byType(Text),
          )
          .first,
    )
    .data!
    .toLowerCase();

/// Open the mode dropdown and tap one of its rows. A disabled row leaves the
/// menu open, so callers testing that path dismiss it themselves.
Future<void> _openModeMenu(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('new-session-mode-chip')));
  await tester.pumpAndSettle();
}

Future<void> _pickMode(WidgetTester tester, String mode) async {
  await _openModeMenu(tester);
  await tester.tap(find.byKey(Key('new-session-mode-$mode')));
  await tester.pumpAndSettle();
}

Widget _host({
  required List<Override> overrides,
  StartNewSessionCallback? submit,
  VoidCallback? onOpenFolder,
  Widget Function(Widget composer)? wrap,
}) {
  final composer = NewSessionComposer(
    onOpenFolder: onOpenFolder ?? () {},
    submit: submit ?? (_, {allowActiveSessions = false}) async {},
  );
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: buildAbTheme(),
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: wrap != null ? wrap(composer) : composer,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
    'typing and pressing Enter writes prompt provider and triggers submit',
    (tester) async {
      var submitCount = 0;
      await tester.pumpWidget(
        _host(
          overrides: _baseOverrides(target: _project),
          submit: (ref, {allowActiveSessions = false}) async {
            submitCount++;
          },
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );

      await tester.enterText(
        find.byKey(const Key('new-session-prompt-field')),
        'fix the bug',
      );
      await tester.pump();

      expect(container.read(newSessionPromptProvider), 'fix the bug');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(submitCount, 1);
    },
  );

  testWidgets('Shift+Enter inserts a newline instead of submitting', (
    tester,
  ) async {
    var submitCount = 0;
    await tester.pumpWidget(
      _host(
        overrides: _baseOverrides(target: _project),
        submit: (ref, {allowActiveSessions = false}) async {
          submitCount++;
        },
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );

    await tester.enterText(
      find.byKey(const Key('new-session-prompt-field')),
      'line one',
    );
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();

    expect(submitCount, 0);
    expect(container.read(newSessionPromptProvider), contains('\n'));
  });

  testWidgets('custom agent disables the input and requires a command', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        overrides: [
          ..._baseOverrides(target: _project),
          newSessionAgentProvider.overrideWith(
            () => ValueController(const CustomAgent()),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final promptField = tester.widget<TextField>(
      find.byKey(const Key('new-session-prompt-field')),
    );
    expect(promptField.enabled, isFalse);

    final sendButtonBefore = tester.widget<ComposerSendButton>(
      find.byKey(const Key('new-session-send-button')),
    );
    expect(sendButtonBefore.onTap, isNull);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );
    container
        .read(newSessionCustomCmdProvider.notifier)
        .set('my-agent --serve');
    await tester.pumpAndSettle();

    final sendButtonAfter = tester.widget<ComposerSendButton>(
      find.byKey(const Key('new-session-send-button')),
    );
    expect(sendButtonAfter.onTap, isNotNull);
  });

  testWidgets('no target: send disabled, chip shows Select project…', (
    tester,
  ) async {
    await tester.pumpWidget(_host(overrides: _baseOverrides()));
    await tester.pumpAndSettle();

    expect(find.text('Select project…'), findsOneWidget);

    final sendButton = tester.widget<ComposerSendButton>(
      find.byKey(const Key('new-session-send-button')),
    );
    expect(sendButton.onTap, isNull);
  });

  testWidgets('context row survives a long machine label at phone width', (
    tester,
  ) async {
    // A machine label carrying its device-uuid suffix used to push the
    // environment + project chips past a 1080px-class phone width, tripping
    // the render overflow (which flutter_test surfaces as a test failure).
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        overrides: [
          pickerSourcesProvider.overrideWithValue(const [
            PickerSource(
              id: 'machine:M',
              label: 'RadhaAI - 96352d',
              isLocal: false,
              projects: [],
              machineUuid: 'M',
            ),
          ]),
          newSessionDetectedToolsProvider.overrideWith(
            (ref) async => const <String, String?>{},
          ),
          newSessionChatCapableToolsProvider.overrideWith((ref) async => null),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('RadhaAI - 96352d'), findsOneWidget);
    expect(find.text('Select project…'), findsOneWidget);
  });

  testWidgets('full context row keeps the branch legible at phone width', (
    tester,
  ) async {
    // Every term of the row long at once — a machine name, a project name, a
    // branch AND the worktree chip. The chips' own chrome (glyph + chevron +
    // padding) already exceeded what a phone row could hand out, so the branch
    // slot fell below the chip's floor and overflowed by ~17px, rendering as a
    // glyph and a chevron either side of nothing.
    const machine = 'DESKTOP-TMDH9M9';
    const project = PickerProject(
      id: 'p-iter-compiler',
      name: 'iter-compiler',
      detail: '/home/me/iter-compiler',
      isLocal: false,
      machineUuid: 'M',
    );
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _host(
        overrides: _baseOverrides(
          target: project,
          worktreeSupported: true,
          currentBranch: 'Revoke1',
          sources: const [
            PickerSource(
              id: 'machine:M',
              label: machine,
              isLocal: false,
              projects: [project],
              machineUuid: 'M',
            ),
          ],
        ),
        // The canvas pads the composer; without it the row under test is
        // wider than the phone it is meant to reproduce.
        wrap: (composer) =>
            Padding(padding: const EdgeInsets.all(16), child: composer),
      ),
    );
    await tester.pumpAndSettle();

    // Ellipsized text keeps its full data, so finding the label is proof the
    // chip still renders one — the state the overflow destroyed.
    expect(find.text(machine), findsOneWidget);
    expect(find.text('iter-compiler'), findsOneWidget);
    expect(find.text('Revoke1'), findsOneWidget);

    // One line, and every chip still the same height: a chip that sheds its
    // label must not shed the label's line box with it.
    final row = <Finder>[
      find.byType(EnvironmentChip),
      find.byType(ProjectChip),
      find.byType(BranchChip),
      find.byKey(const Key('new-session-worktree-chip')),
    ];
    for (final chip in row) {
      expect(tester.getCenter(chip).dy, tester.getCenter(row.first).dy);
      expect(tester.getSize(chip).height, tester.getSize(row.first).height);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('terminal-only agent pins mode to TERMINAL, Chat cell dead', (
    tester,
  ) async {
    // Empty (non-null) wire chatCapable set excludes every agent, so the
    // resolved support is false regardless of the static fallback list.
    await tester.pumpWidget(
      _host(
        overrides: _baseOverrides(target: _project, chatCapable: const {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(_selectedMode(tester), 'terminal');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );
    // Tapping the disabled Chat row must not change the mode, and must not
    // close the menu. (On the default Android test platform the tap surfaces
    // the reason as a snack bar — pump past its duration so its dismiss timer
    // isn't pending at test end.)
    await _openModeMenu(tester);
    await tester.tap(find.byKey(const Key('new-session-mode-chat')));
    await tester.pumpAndSettle();

    expect(container.read(newSessionModeProvider), 'terminal');
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(_selectedMode(tester), 'terminal');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Esc bubbles to an ancestor binding instead of being swallowed by the '
    'empty prompt field',
    (tester) async {
      var escaped = false;
      await tester.pumpWidget(
        _host(
          overrides: _baseOverrides(target: _project),
          wrap: (composer) => CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  escaped = true,
            },
            child: Focus(autofocus: true, child: composer),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('new-session-prompt-field')));
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(escaped, isTrue);
    },
  );

  testWidgets('gear popover edits session name via newSessionNameProvider', (
    tester,
  ) async {
    await tester.pumpWidget(_host(overrides: _baseOverrides(target: _project)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-gear-button')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('new-session-gear-name')),
      'my session',
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );
    expect(container.read(newSessionNameProvider), 'my session');
  });

  testWidgets('YOLO is capability-gated and requires risk confirmation', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        overrides: [
          ..._baseOverrides(target: _project),
          newSessionAgentProvider.overrideWith(
            () => ValueController(const KnownAgent('codex')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-gear-button')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-gear-yolo')));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'This agent will bypass approval prompts and disable sandboxing for this session.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Enable YOLO'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );
    expect(container.read(newSessionApprovalPolicyProvider), 'bypass');
  });

  testWidgets('custom commands cannot enable YOLO', (tester) async {
    await tester.pumpWidget(
      _host(
        overrides: [
          ..._baseOverrides(target: _project),
          newSessionAgentProvider.overrideWith(
            () => ValueController(const CustomAgent()),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('new-session-gear-button')));
    await tester.pumpAndSettle();

    expect(find.text('Not supported for this agent and mode'), findsOneWidget);
    final toggle = tester.widget<AbSwitch>(
      find.byKey(const Key('new-session-gear-yolo')),
    );
    expect(toggle.onChanged, isNull);
  });

  testWidgets('agent selector picks an agent and sets the touched flag', (
    tester,
  ) async {
    await tester.pumpWidget(_host(overrides: _baseOverrides(target: _project)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('new-session-agent-selector')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );
    expect(container.read(newSessionAgentProvider), const KnownAgent('codex'));
    expect(container.read(newSessionAgentTouchedProvider), isTrue);
  });

  testWidgets('manual mode toggle survives a chat-capability re-emission', (
    tester,
  ) async {
    // Desktop layout: flutter_test otherwise defaults to Android, which
    // short-circuits some desktop UI paths.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await tester.pumpWidget(
      _host(
        overrides: [
          pickerSourcesProvider.overrideWithValue(const [_localSource]),
          newSessionDetectedToolsProvider.overrideWith(
            (ref) async => const {'claude-code': 'Claude Code'},
          ),
          newSessionChatCapableToolsProvider.overrideWith(
            (ref) async => ref.watch(_chatCapDriver),
          ),
          selectedTargetProjectProvider.overrideWith(
            () => ValueController(_project),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );

    // Terminal is the default even for chat-capable claude-code.
    expect(container.read(newSessionModeProvider), 'terminal');
    expect(_selectedMode(tester), 'terminal');

    // User explicitly switches to Chat.
    await _pickMode(tester, 'chat');
    expect(container.read(newSessionModeProvider), 'chat');

    // An unrelated control-plane push re-emits chat-capability (fresh Set,
    // reference-distinct). The manual Chat choice must survive.
    container.read(_chatCapDriver.notifier).set({'claude-code'});
    await tester.pumpAndSettle();

    expect(container.read(newSessionModeProvider), 'chat');
    expect(_selectedMode(tester), 'chat');

    // Reset inside the body: the framework's foundation-var invariant check
    // runs before addTearDown, so the safety-net tearDown alone isn't enough.
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'remount after an off-screen chat-capability re-emission does not crash '
    'the build (autoDispose regression)',
    (tester) async {
      // Repro of the "UncontrolledProviderScope cannot be marked as needing to
      // build ... currently building NewSessionComposer" crash: while the
      // composer is unmounted, a control-plane push re-emits
      // newSessionChatCapableToolsProvider. If that provider (and its sync
      // dependent newSessionSupportsChatProvider) outlive the composer, the
      // next mount's `ref.listen` flushes the stale provider mid-build and
      // synchronously reschedules the still-live dependent via setState on the
      // scope — illegal during build. autoDispose disposes both with the
      // composer, so each mount starts clean. Guards against dropping it.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            pickerSourcesProvider.overrideWithValue(const [_localSource]),
            newSessionDetectedToolsProvider.overrideWith(
              (ref) async => const {'claude-code': 'Claude Code'},
            ),
            newSessionChatCapableToolsProvider.overrideWith(
              (ref) async => ref.watch(_chatCapDriver),
            ),
            selectedTargetProjectProvider.overrideWith(
              () => ValueController(_project),
            ),
          ],
          child: MaterialApp(
            theme: buildAbTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Consumer(
                  builder: (context, ref, _) => ref.watch(_composerVisible)
                      ? NewSessionComposer(
                          onOpenFolder: () {},
                          submit: (_, {allowActiveSessions = false}) async {},
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      // Sanity: the dependent is alive and resolved.
      expect(container.read(newSessionModeProvider), 'terminal');

      // Composer leaves the tree.
      container.read(_composerVisible.notifier).set(false);
      await tester.pumpAndSettle();
      expect(find.byType(NewSessionComposer), findsNothing);

      // Off-screen control-plane push re-emits a reference-distinct Set, then
      // the composer re-mounts in the same turn — so the provider is still
      // dirty when the new build's `ref.listen` flushes it.
      container.read(_chatCapDriver.notifier).set({'claude-code'});
      container.read(_composerVisible.notifier).set(true);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(NewSessionComposer), findsOneWidget);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  // Ported from the deleted test/widgets/new_session_mode_toggle_test.dart
  // (SessionConfig's mode toggle), retargeted onto the composer's mode
  // dropdown. No wire chatCapable data (chatCapable: null, the _baseOverrides
  // default) → the persisted agent catalog governs, which is what's under
  // test here: every agent starts on Terminal, and a chat-capable one can be
  // switched to Chat while the rest keep a dead Chat row.
  group('mode control: catalog fallback (no wire chatCapable data)', () {
    testWidgets('codex agent: defaults to Terminal, Chat selectable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          overrides: [
            ..._baseOverrides(),
            newSessionAgentProvider.overrideWith(
              () => ValueController(const KnownAgent('codex')),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionModeProvider), 'terminal');
      expect(_selectedMode(tester), 'terminal');

      await _pickMode(tester, 'chat');
      expect(container.read(newSessionModeProvider), 'chat');
      expect(_selectedMode(tester), 'chat');
    });

    testWidgets('claudeCode agent: defaults to Terminal, Chat selectable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          overrides: [
            ..._baseOverrides(),
            newSessionAgentProvider.overrideWith(
              () => ValueController(kDefaultSessionAgent),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionModeProvider), 'terminal');
      expect(_selectedMode(tester), 'terminal');

      await _pickMode(tester, 'chat');
      expect(container.read(newSessionModeProvider), 'chat');
      expect(_selectedMode(tester), 'chat');
    });

    testWidgets(
      'cursorAgent: Chat row disabled, mode forced Terminal, taps ignored',
      (tester) async {
        await tester.pumpWidget(
          _host(
            overrides: [
              ..._baseOverrides(),
              newSessionAgentProvider.overrideWith(
                () => ValueController(const KnownAgent('cursor-agent')),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(NewSessionComposer)),
        );
        expect(container.read(newSessionModeProvider), 'terminal');
        expect(_selectedMode(tester), 'terminal');

        await _openModeMenu(tester);
        await tester.tap(find.byKey(const Key('new-session-mode-chat')));
        await tester.pumpAndSettle();

        expect(container.read(newSessionModeProvider), 'terminal');
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(_selectedMode(tester), 'terminal');
        // Drain the disabled-tap snack bar's dismiss timer (Android default
        // test platform takes the mobile feedback path).
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'an agent nothing has described reads as unknown, not unsupported',
      (tester) async {
        // Neither the target machine nor the catalog has said. The cell is dead
        // either way, but the reason must not blame the agent for a capability
        // nobody asserted — the app no longer ships a table that could answer.
        await tester.pumpWidget(
          _host(
            overrides: [
              ..._baseOverrides(catalog: const {}),
              newSessionAgentProvider.overrideWith(
                () => ValueController(const KnownAgent('kilo')),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(NewSessionComposer)),
        );
        expect(container.read(newSessionSupportsChatProvider), isNull);
        expect(container.read(newSessionModeProvider), 'terminal');
        expect(_selectedMode(tester), 'terminal');
      },
    );
  });

  group('isolation chip', () {
    // The key addresses the isolation toggle, not the word printed on it.
    Finder chip() => find.byKey(const Key('new-session-worktree-chip'));

    testWidgets('toggles isolation and re-labels the branch chip', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          overrides: _baseOverrides(target: _project, worktreeSupported: true),
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionIsolatedProvider), isFalse);
      expect(find.text('main'), findsOneWidget);

      await tester.tap(chip());
      await tester.pumpAndSettle();

      expect(container.read(newSessionIsolatedProvider), isTrue);
      // The neighbouring chip is the feedback: the branch becomes a base.
      expect(find.text('Base: main'), findsOneWidget);

      await tester.tap(chip());
      await tester.pumpAndSettle();

      expect(container.read(newSessionIsolatedProvider), isFalse);
    });

    testWidgets('a bridge without worktree support renders a dead chip', (
      tester,
    ) async {
      // worktreeSupported defaults to false — the capability is per-host, so
      // the chip must stay inert rather than promise an isolation the bridge
      // will refuse.
      await tester.pumpWidget(
        _host(overrides: _baseOverrides(target: _project)),
      );
      await tester.pumpAndSettle();

      await tester.tap(chip());
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionIsolatedProvider), isFalse);
    });

    testWidgets('stays on the context row line when the branch is long', (
      tester,
    ) async {
      // A managed session's generated branch, prefixed with "Base: " once
      // isolation is on, is long enough to have folded the chip row onto a
      // second line back when it was a Wrap. The branch must absorb the
      // squeeze instead — a target stated across two lines reads as two
      // unrelated fragments.
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _host(
          overrides: _baseOverrides(
            target: _project,
            worktreeSupported: true,
            currentBranch: 'antgrid/some-very-long-generated-session-e529cdaf',
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(chip());
      await tester.pumpAndSettle();

      // Same vertical centre as the first chip = same run. (An overflow would
      // already have failed the test on its own.)
      expect(
        tester.getCenter(chip()).dy,
        tester.getCenter(find.byType(EnvironmentChip)).dy,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('is absent until a project is chosen', (tester) async {
      await tester.pumpWidget(_host(overrides: _baseOverrides()));
      await tester.pumpAndSettle();

      expect(chip(), findsNothing);
    });
  });

  group('Branch switch confirmation dialog', () {
    testWidgets(
      'shows AbConfirmDialog on ActiveSessionsBranchSwitchException and retries when confirmed',
      (tester) async {
        var submitCalls = <bool>[];
        await tester.pumpWidget(
          _host(
            overrides: [
              ..._baseOverrides(target: _project),
              newSessionBranchSelectionProvider.overrideWith(
                () => ValueController(
                  const NewSessionBranchSelection(
                    targetId: 'p-my-repo',
                    branch: 'dev',
                  ),
                ),
              ),
            ],
            submit: (ref, {allowActiveSessions = false}) async {
              submitCalls.add(allowActiveSessions);
              if (!allowActiveSessions) {
                throw ActiveSessionsBranchSwitchException(
                  targetId: _project.id,
                  branch: 'dev',
                );
              }
            },
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('new-session-prompt-field')),
          'start session',
        );
        await tester.pump();

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(submitCalls, [false]);
        expect(find.text('Switch branch?'), findsOneWidget);

        await tester.tap(find.text('Switch & start'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));

        expect(submitCalls, [false, true]);
      },
    );

    testWidgets('surfaces an error when the confirmed retry fails', (
      tester,
    ) async {
      var submitCalls = <bool>[];
      await tester.pumpWidget(
        _host(
          overrides: [
            ..._baseOverrides(target: _project),
            newSessionBranchSelectionProvider.overrideWith(
              () => ValueController(
                const NewSessionBranchSelection(
                  targetId: 'p-my-repo',
                  branch: 'dev',
                ),
              ),
            ),
          ],
          submit: (ref, {allowActiveSessions = false}) async {
            submitCalls.add(allowActiveSessions);
            if (!allowActiveSessions) {
              throw ActiveSessionsBranchSwitchException(
                targetId: _project.id,
                branch: 'dev',
              );
            }
            throw StateError('checkout failed');
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('new-session-prompt-field')),
        'start session',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Switch & start'));
      await tester.pump();

      expect(submitCalls, [false, true]);
      expect(find.textContaining('Failed to start session'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  group('create-time isolation refusals', () {
    /// Submits, then settles far enough for the refusal's snack bar to render.
    Future<void> submitPrompt(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('new-session-prompt-field')),
        'start session',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    /// Drains the 8s snack bar so its dismiss timer can't outlive the test.
    Future<void> drainSnackBar(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 8));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Widget refusingHost(SessionOperationException refusal) => _host(
      overrides: _baseOverrides(target: _project),
      submit: (ref, {allowActiveSessions = false}) async => throw refusal,
    );

    testWidgets('a mapped code replaces the bridge wording', (tester) async {
      await tester.pumpWidget(
        refusingHost(
          const SessionOperationException(
            'UNKNOWN_BASE_BRANCH',
            'unknown base branch: nope',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await submitPrompt(tester);

      expect(
        find.text(friendlyErrorCopy('UNKNOWN_BASE_BRANCH')!),
        findsOneWidget,
      );
      // The generic arm would have printed the exception itself — which is what
      // made friendlyErrorCopy's isolation arms unreachable from this path.
      expect(find.textContaining('Failed to start session'), findsNothing);
      expect(find.textContaining('unknown base branch'), findsNothing);

      await drainSnackBar(tester);
    });

    testWidgets('an unmapped code keeps the bridge message', (tester) async {
      await tester.pumpWidget(
        refusingHost(
          const SessionOperationException(
            'WORKTREE_CREATE_FAILED',
            'fatal: invalid reference: nope',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await submitPrompt(tester);

      expect(find.text('fatal: invalid reference: nope'), findsOneWidget);

      await drainSnackBar(tester);
    });

    testWidgets('a refusal carrying neither falls back', (tester) async {
      await tester.pumpWidget(
        refusingHost(const SessionOperationException(null, null)),
      );
      await tester.pumpAndSettle();
      await submitPrompt(tester);

      expect(find.text('Could not start the session.'), findsOneWidget);

      await drainSnackBar(tester);
    });

    testWidgets('the composer stays put with the prompt intact', (
      tester,
    ) async {
      // A refused create/start must not navigate: the whole point of reporting
      // it here is that the user can fix the target and press Enter again.
      await tester.pumpWidget(
        refusingHost(
          const SessionOperationException('WORKTREE_UNSUPPORTED', 'nope'),
        ),
      );
      await tester.pumpAndSettle();
      await submitPrompt(tester);

      expect(find.byType(NewSessionComposer), findsOneWidget);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionPromptProvider), 'start session');
      expect(
        find.text(friendlyErrorCopy('WORKTREE_UNSUPPORTED')!),
        findsOneWidget,
      );

      await drainSnackBar(tester);
    });
  });

  group('start lock', () {
    void begin(
      ProviderContainer container, {
      NewSessionStartPhase phase = NewSessionStartPhase.activating,
      String? branch,
    }) {
      container
          .read(newSessionStartProgressProvider.notifier)
          .begin(
            phase: phase,
            targetId: _project.id,
            targetName: _project.name,
            deviceName: 'mac-studio',
            agentLabel: 'Claude Code',
            isolated: false,
            title: 'fix the bug',
            branch: branch,
          );
    }

    void advance(ProviderContainer container, NewSessionStartPhase phase) =>
        container.read(newSessionStartProgressProvider.notifier).advance(phase);

    ProviderContainer containerOf(WidgetTester tester) =>
        ProviderScope.containerOf(
          tester.element(find.byType(NewSessionComposer)),
        );

    /// Never `pumpAndSettle` while a start is armed: the status line and the
    /// busy send button both run a repeating `AbLoadingDot` controller.
    Future<void> settle(WidgetTester tester) =>
        tester.pump(const Duration(milliseconds: 400));

    String statusText(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const Key('new-session-status-line')),
            matching: find.byType(Text),
          ),
        )
        .data!;

    Finder sendButton() => find.byKey(const Key('new-session-send-button'));
    Finder stopButton() => find.byKey(const Key('new-session-stop-button'));

    testWidgets('every control in the form refuses taps', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(
        _host(
          overrides: _baseOverrides(target: _project, worktreeSupported: true),
        ),
      );
      await tester.pumpAndSettle();

      final container = containerOf(tester);
      begin(container);
      await settle(tester);

      // Real taps, because a control that only LOOKS dead still opens its
      // panel — which is the state the form shipped in.
      Future<void> tapDead(Finder target) async {
        await tester.tap(target, warnIfMissed: false);
        await settle(tester);
      }

      await tapDead(find.byType(EnvironmentChip));
      expect(find.text('Machines'), findsNothing);

      await tapDead(find.byType(ProjectChip));
      expect(find.text('Open folder…'), findsNothing);

      await tapDead(find.byType(BranchChip));
      expect(find.text('Search branches…'), findsNothing);

      await tapDead(find.byKey(const Key('new-session-worktree-chip')));
      expect(container.read(newSessionIsolatedProvider), isFalse);

      await tapDead(find.byKey(const Key('new-session-mode-chip')));
      expect(find.byKey(const Key('new-session-mode-chat')), findsNothing);
      expect(container.read(newSessionModeProvider), 'terminal');

      await tapDead(find.byKey(const Key('new-session-gear-button')));
      expect(find.text('Session settings'), findsNothing);

      await tapDead(find.byKey(const Key('new-session-agent-selector')));
      expect(find.text('Codex'), findsNothing);
      expect(container.read(newSessionAgentProvider), kDefaultSessionAgent);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the prompt is frozen and Enter cannot resubmit', (
      tester,
    ) async {
      // Desktop, or this asserts nothing: on a mobile platform the start's own
      // listener drops prompt focus, so the Enter below never reaches
      // `_onPromptKeyEvent` and passes with the in-flight guard deleted.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      var submitCount = 0;
      await tester.pumpWidget(
        _host(
          overrides: _baseOverrides(target: _project),
          submit: (ref, {allowActiveSessions = false}) async {
            submitCount++;
          },
        ),
      );
      await tester.pumpAndSettle();

      final container = containerOf(tester);
      await tester.enterText(
        find.byKey(const Key('new-session-prompt-field')),
        'fix the bug',
      );
      await tester.pump();

      begin(container);
      await settle(tester);

      final field = tester.widget<TextField>(
        find.byKey(const Key('new-session-prompt-field')),
      );
      // Frozen, not disabled: the prompt already on the wire is the thing the
      // user is waiting on, so it stays legible and undimmed.
      expect(field.readOnly, isTrue);
      expect(field.enabled, isTrue);
      expect(field.showCursor, isFalse);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(tester);

      expect(submitCount, 0);
      expect(container.read(newSessionPromptProvider), 'fix the bug');

      // Shift+Enter writes the controller directly, so read-only alone would
      // still let it edit a prompt that is already being started with.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await settle(tester);

      expect(container.read(newSessionPromptProvider), 'fix the bug');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('send becomes Stop, then a plain busy button past the '
        'cancel boundary', (tester) async {
      await tester.pumpWidget(
        _host(overrides: _baseOverrides(target: _project)),
      );
      await tester.pumpAndSettle();

      final container = containerOf(tester);
      expect(stopButton(), findsNothing);
      expect(tester.widget<ComposerSendButton>(sendButton()).busy, isFalse);

      begin(container);
      await settle(tester);

      expect(stopButton(), findsOneWidget);
      await tester.tap(sendButton());
      await settle(tester);

      expect(container.read(newSessionStartCancelRequestedProvider), isTrue);
      expect(statusText(tester), 'Cancelling...');

      // Past `creating` the bridge already holds a session, so abandoning the
      // start would orphan it: the affordance goes away rather than lying.
      advance(container, NewSessionStartPhase.creating);
      await settle(tester);

      expect(stopButton(), findsNothing);
      final busy = tester.widget<ComposerSendButton>(sendButton());
      expect(busy.busy, isTrue);
      expect(busy.onTap, isNull);
      expect(
        container
            .read(newSessionStartProgressProvider.notifier)
            .requestCancel(),
        isFalse,
      );

      container.read(newSessionStartProgressProvider.notifier).end();
      await tester.pumpAndSettle();

      expect(stopButton(), findsNothing);
      expect(find.byKey(const Key('new-session-status-line')), findsNothing);
      expect(tester.widget<ComposerSendButton>(sendButton()).busy, isFalse);
    });

    testWidgets('the status line names the stage the start has reached', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      await tester.pumpWidget(
        _host(overrides: _baseOverrides(target: _project)),
      );
      await tester.pumpAndSettle();

      final container = containerOf(tester);
      begin(
        container,
        phase: NewSessionStartPhase.switchingBranch,
        branch: 'dev',
      );
      await settle(tester);

      expect(find.byKey(const Key('new-session-status-line')), findsOneWidget);
      expect(statusText(tester), 'Switching to dev...');

      const expected = {
        NewSessionStartPhase.activating: 'Waking mac-studio...',
        NewSessionStartPhase.connecting: 'Starting project...',
        NewSessionStartPhase.preparing: 'Preparing workspace...',
        NewSessionStartPhase.creating: 'Creating session...',
        NewSessionStartPhase.launching: 'Launching Claude Code...',
      };
      for (final entry in expected.entries) {
        advance(container, entry.key);
        await settle(tester);
        expect(statusText(tester), entry.value);
      }

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the status line is shown on mobile too', (tester) async {
      // The Enter hint is desktop-only, but a cold remote start is a 30s wait
      // and a phone is where it is most often watched.
      await tester.pumpWidget(
        _host(overrides: _baseOverrides(target: _project)),
      );
      await tester.pumpAndSettle();

      expect(isMobilePlatform, isTrue);
      expect(find.byKey(const Key('new-session-status-line')), findsNothing);

      final container = containerOf(tester);
      begin(container, phase: NewSessionStartPhase.connecting);
      await settle(tester);

      expect(find.byKey(const Key('new-session-status-line')), findsOneWidget);
      expect(statusText(tester), 'Starting project...');
      expect(stopButton(), findsOneWidget);
    });

    /// Mounts the composer with the prompt focused and hands back its node.
    Future<FocusNode> focusedPrompt(WidgetTester tester) async {
      await tester.pumpWidget(
        _host(overrides: _baseOverrides(target: _project)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-session-prompt-field')));
      await tester.pumpAndSettle();
      final node = tester
          .widget<TextField>(find.byKey(const Key('new-session-prompt-field')))
          .focusNode!;
      expect(node.hasFocus, isTrue);
      return node;
    }

    testWidgets('a touch start drops the prompt focus', (tester) async {
      // Flipping the prompt to readOnly closes the platform input connection on
      // a touch platform, so the soft keyboard collapses on Send and — with
      // focus still on the field — springs back the instant the start ends,
      // over a form the user was not typing in and over the snackbar saying
      // why. Dropping focus makes that close deliberate and one-way.
      expect(isMobilePlatform, isTrue);
      final node = await focusedPrompt(tester);

      begin(containerOf(tester));
      await settle(tester);

      expect(node.hasFocus, isFalse);
    });

    testWidgets('a desktop start keeps it', (tester) async {
      // No soft keyboard to collapse, and Enter-to-start is how a retry after
      // an abort is typed — taking focus away would cost a click every time.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final node = await focusedPrompt(tester);

      begin(containerOf(tester));
      await settle(tester);

      expect(node.hasFocus, isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('an ended start never fades the Enter hint out in its place', (
      tester,
    ) async {
      // Desktop-roomy is the one shape where the slot survives a start ending
      // (a phone, or a narrow pane, drops it wholesale). With the prompt
      // unfocused the slot turns invisible on the same frame as the phase line
      // is replaced by the Enter hint, so unless the two children animate
      // separately the fade-out plays on the hint — text that was never on
      // screen, dissolving out of a slot the user was reading a stage name in.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      double slotOpacity() => tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(AbCrossFade),
              matching: find.byType(Opacity),
            ),
          )
          .opacity;

      await tester.pumpWidget(
        _host(overrides: _baseOverrides(target: _project)),
      );
      await tester.pumpAndSettle();
      expect(slotOpacity(), 0);

      final container = containerOf(tester);
      begin(container);
      await tester.pump();
      await settle(tester);
      expect(find.byKey(const Key('new-session-status-line')), findsOneWidget);
      expect(slotOpacity(), 1);

      container.read(newSessionStartProgressProvider.notifier).end();
      await tester.pump();

      // The frame the swap lands on, and every frame a fade would have run
      // through: the hint is already gone, not on its way out.
      expect(find.byKey(const Key('new-session-status-line')), findsNothing);
      expect(slotOpacity(), 0);
      await tester.pump(const Duration(milliseconds: 60));
      expect(slotOpacity(), 0);

      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a remount mid-start hands back a form that is still locked', (
      tester,
    ) async {
      // The lock lives in a provider, not in this State: the New Session screen
      // builds a different tree either side of the compact breakpoint, so a
      // resize mid-start disposes the composer — and a widget-local flag came
      // back cleared while the start it was guarding ran on.
      await tester.pumpWidget(
        ProviderScope(
          overrides: _baseOverrides(target: _project, worktreeSupported: true),
          child: MaterialApp(
            theme: buildAbTheme(),
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: Consumer(
                  builder: (context, ref, _) => ref.watch(_composerVisible)
                      ? NewSessionComposer(
                          onOpenFolder: () {},
                          submit: (_, {allowActiveSessions = false}) async {},
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final container = containerOf(tester);
      final before = tester.state<State>(find.byType(NewSessionComposer));

      begin(container);
      await settle(tester);
      expect(stopButton(), findsOneWidget);

      container.read(_composerVisible.notifier).set(false);
      await settle(tester);
      expect(find.byType(NewSessionComposer), findsNothing);

      container.read(_composerVisible.notifier).set(true);
      await settle(tester);

      // A genuine remount, not a rebuild: the old State was disposed.
      final after = tester.state<State>(find.byType(NewSessionComposer));
      expect(identical(before, after), isFalse);

      expect(stopButton(), findsOneWidget);
      expect(statusText(tester), 'Waking mac-studio...');
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('new-session-prompt-field')),
            )
            .readOnly,
        isTrue,
      );

      await tester.tap(
        find.byKey(const Key('new-session-worktree-chip')),
        warnIfMissed: false,
      );
      await settle(tester);
      expect(container.read(newSessionIsolatedProvider), isFalse);

      advance(container, NewSessionStartPhase.creating);
      await settle(tester);

      final send = tester.widget<ComposerSendButton>(sendButton());
      expect(send.onTap, isNull);
      expect(send.busy, isTrue);
    });
  });
}
