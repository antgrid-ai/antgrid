import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
import 'package:antgrid/design/widgets/ab_segmented.dart';
import 'package:antgrid/models/git_branch.dart';
import 'package:antgrid/providers/new_session_action.dart';
import 'package:antgrid/providers/new_session_picker.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/widgets/new_session/new_session_composer.dart';
import 'package:antgrid/widgets/new_session/picker_sources.dart';

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

/// Base overrides every test needs: one local source, and detection/chat-
/// capability futures stubbed so the widget never touches a real host
/// controller. Callers append target/agent overrides on top.
List<Override> _baseOverrides({
  PickerProject? target,
  Map<String, String?> detected = const <String, String?>{},
  Set<String>? chatCapable,
}) {
  return [
    pickerSourcesProvider.overrideWithValue(const [_localSource]),
    newSessionDetectedToolsProvider.overrideWith((ref) async => detected),
    newSessionChatCapableToolsProvider.overrideWith((ref) async => chatCapable),
    newSessionBranchCatalogProvider.overrideWith(
      (ref) async => target == null
          ? null
          : const GitBranchCatalog(
              isRepository: true,
              current: 'main',
              branches: ['main', 'dev'],
            ),
    ),
    if (target != null)
      selectedTargetProjectProvider.overrideWith(() => ValueController(target)),
  ];
}

/// The mode segmented control renders BOTH labels at all times, so
/// `find.text('CHAT')` no longer distinguishes the current mode — read the
/// selection off the widget instead.
String _selectedMode(WidgetTester tester) => tester
    .widget<AbSegmented<String>>(
      find.byKey(const Key('new-session-mode-chip')),
    )
    .selected;

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
    // Tapping the disabled Chat cell must not change the mode. (On the
    // default Android test platform the tap surfaces the reason as a snack
    // bar — pump past its duration so its dismiss timer isn't pending at
    // test end.)
    await tester.tap(find.byKey(const Key('new-session-mode-chat')));
    await tester.pumpAndSettle();

    expect(container.read(newSessionModeProvider), 'terminal');
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

    // Chat-capable claude-code → mode defaults to Chat.
    expect(container.read(newSessionModeProvider), 'chat');
    expect(_selectedMode(tester), 'chat');

    // User explicitly switches to Terminal.
    await tester.tap(find.byKey(const Key('new-session-mode-terminal')));
    await tester.pumpAndSettle();
    expect(container.read(newSessionModeProvider), 'terminal');

    // An unrelated control-plane push re-emits chat-capability (fresh Set,
    // reference-distinct). The manual Terminal choice must survive.
    container.read(_chatCapDriver.notifier).set({'claude-code'});
    await tester.pumpAndSettle();

    expect(container.read(newSessionModeProvider), 'terminal');
    expect(_selectedMode(tester), 'terminal');

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
      // Sanity: the dependent is alive and resolved (chat-capable → Chat).
      expect(container.read(newSessionModeProvider), 'chat');

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
  // segmented control. No wire chatCapable data (chatCapable: null, the
  // _baseOverrides default) → the static fallback (newSessionAgentSupportsChat)
  // governs, which is what's under test here: chat-capable agents default to
  // Chat, others are pinned to Terminal with a dead Chat cell.
  group('mode control: static-fallback matrix (no wire chatCapable data)', () {
    testWidgets('codex agent: control enabled and defaults to Chat', (
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
      expect(container.read(newSessionModeProvider), 'chat');
      expect(_selectedMode(tester), 'chat');
    });

    testWidgets('claudeCode agent: control enabled and defaults to Chat', (
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
      expect(container.read(newSessionModeProvider), 'chat');
      expect(_selectedMode(tester), 'chat');
    });

    testWidgets(
      'cursorAgent: Chat cell disabled, mode forced Terminal, taps ignored',
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

        await tester.tap(find.byKey(const Key('new-session-mode-chat')));
        await tester.pumpAndSettle();

        expect(container.read(newSessionModeProvider), 'terminal');
        expect(_selectedMode(tester), 'terminal');
        // Drain the disabled-tap snack bar's dismiss timer (Android default
        // test platform takes the mobile feedback path).
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
      },
    );
  });

  group('Branch switch confirmation dialog', () {
    testWidgets('shows AbConfirmDialog on ActiveSessionsBranchSwitchException and retries when confirmed', (tester) async {
      var submitCalls = <bool>[];
      await tester.pumpWidget(
        _host(
          overrides: [
            ..._baseOverrides(target: _project),
            newSessionBranchSelectionProvider.overrideWith(
              () => ValueController(const NewSessionBranchSelection(
                targetId: 'p-my-repo',
                branch: 'dev',
              )),
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
    });

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
}
