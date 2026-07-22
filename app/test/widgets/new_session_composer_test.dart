import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:antgrid/design/ab_theme.dart';
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

/// Base overrides every test needs: one local source, and detection/chat-
/// capability futures stubbed so the widget never touches a real host
/// controller. Callers append target/agent overrides on top.
List<Override> _baseOverrides({
  PickerProject? target,
  Set<String> detected = const <String>{},
  Set<String>? chatCapable,
}) {
  return [
    pickerSourcesProvider.overrideWithValue(const [_localSource]),
    newSessionDetectedToolsProvider.overrideWith((ref) async => detected),
    newSessionChatCapableToolsProvider.overrideWith((ref) async => chatCapable),
    if (target != null)
      selectedTargetProjectProvider.overrideWith(() => ValueController(target)),
  ];
}

Widget _host({
  required List<Override> overrides,
  Future<void> Function(WidgetRef ref)? submit,
  VoidCallback? onOpenFolder,
  Widget Function(Widget composer)? wrap,
}) {
  final composer = NewSessionComposer(
    onOpenFolder: onOpenFolder ?? () {},
    submit: submit ?? (_) async {},
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
          submit: (ref) async {
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
        submit: (ref) async {
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
            () => ValueController(NewSessionAgent.custom),
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

  testWidgets('terminal-only agent pins mode chip to TERMINAL disabled', (
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

    expect(find.text('TERMINAL'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(NewSessionComposer)),
    );
    await tester.tap(find.byKey(const Key('new-session-mode-chip')));
    await tester.pumpAndSettle();

    expect(container.read(newSessionModeProvider), 'terminal');
    expect(find.text('TERMINAL'), findsOneWidget);
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
    expect(container.read(newSessionAgentProvider), NewSessionAgent.codex);
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
            (ref) async => const {'claude-code'},
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

    // Chat-capable claude-code → mode defaults to Chat. (AbChip.toggle
    // uppercases its label.)
    expect(container.read(newSessionModeProvider), 'chat');
    expect(find.text('CHAT'), findsOneWidget);

    // User explicitly switches to Terminal.
    await tester.tap(find.byKey(const Key('new-session-mode-chip')));
    await tester.pumpAndSettle();
    expect(container.read(newSessionModeProvider), 'terminal');

    // An unrelated control-plane push re-emits chat-capability (fresh Set,
    // reference-distinct). The manual Terminal choice must survive.
    container.read(_chatCapDriver.notifier).set({'claude-code'});
    await tester.pumpAndSettle();

    expect(container.read(newSessionModeProvider), 'terminal');
    expect(find.text('TERMINAL'), findsOneWidget);

    // Reset inside the body: the framework's foundation-var invariant check
    // runs before addTearDown, so the safety-net tearDown alone isn't enough.
    debugDefaultTargetPlatformOverride = null;
  });

  // Ported from the deleted test/widgets/new_session_mode_toggle_test.dart
  // (SessionConfig's mode toggle), retargeted onto the composer's mode chip.
  // No wire chatCapable data (chatCapable: null, the _baseOverrides default)
  // → the static fallback (newSessionAgentSupportsChat) governs, which is
  // what's under test here: chat-capable agents default to Chat, others are
  // pinned to Terminal and the chip ignores taps.
  group('mode chip: static-fallback matrix (no wire chatCapable data)', () {
    testWidgets('codex agent: chip enabled and defaults to Chat', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          overrides: [
            ..._baseOverrides(),
            newSessionAgentProvider.overrideWith(
              () => ValueController(NewSessionAgent.codex),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionModeProvider), 'chat');
      expect(find.text('CHAT'), findsOneWidget);
    });

    testWidgets('claudeCode agent: chip enabled and defaults to Chat', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          overrides: [
            ..._baseOverrides(),
            newSessionAgentProvider.overrideWith(
              () => ValueController(NewSessionAgent.claudeCode),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(NewSessionComposer)),
      );
      expect(container.read(newSessionModeProvider), 'chat');
      expect(find.text('CHAT'), findsOneWidget);
    });

    testWidgets(
      'cursorAgent: chip disabled, mode forced Terminal, taps ignored',
      (tester) async {
        await tester.pumpWidget(
          _host(
            overrides: [
              ..._baseOverrides(),
              newSessionAgentProvider.overrideWith(
                () => ValueController(NewSessionAgent.cursorAgent),
              ),
            ],
          ),
        );
        await tester.pumpAndSettle();

        final container = ProviderScope.containerOf(
          tester.element(find.byType(NewSessionComposer)),
        );
        expect(container.read(newSessionModeProvider), 'terminal');
        expect(find.text('TERMINAL'), findsOneWidget);

        await tester.tap(find.byKey(const Key('new-session-mode-chip')));
        await tester.pumpAndSettle();

        expect(container.read(newSessionModeProvider), 'terminal');
        expect(find.text('TERMINAL'), findsOneWidget);
      },
    );
  });
}
