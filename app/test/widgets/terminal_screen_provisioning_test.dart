// While `worktree.setup` runs, the bridge HOLDS the session's `session:start`,
// so the entry reports `running: false` for the whole run with
// `setup.pendingStart` set. The terminal pane read that flag as "stopped" and
// offered a Start button whose press re-entered the same gate, changed nothing
// and reported nothing — a dead control under a banner saying the workspace was
// being prepared. These pin the pane's side of "a queued start is not a stopped
// session"; the auto-start paths that share the rule are pinned by
// `new_session_queued_start_test.dart` and `session_setup_test.dart`.
import 'dart:async';

import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/checkout_readiness.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/checkout_readiness.dart'
    show checkoutReadinessProvider;
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/screens/terminal_screen.dart';
import 'package:antgrid/services/sessions_service.dart';
import 'package:antgrid/widgets/agent_panel.dart';
import 'package:antgrid/widgets/session_setup_progress.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';
import '../helpers/toast_host.dart';

const _projectId = 'P';
const _sessionId = 's1';

SessionSetup _setup({required bool pendingStart}) => SessionSetup(
  state: 'running',
  stepIndex: 1,
  stepCount: 4,
  stepName: 'Install dependencies',
  stepNames: const [
    'Copy env files',
    'Install dependencies',
    'Generate client',
    'Build assets',
  ],
  terminalId: 'worktree-1:setup',
  pendingStart: pendingStart,
  startedAt: 1700,
);

SessionEntry _entry(SessionSetup? setup) => SessionEntry(
  id: _sessionId,
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  // The whole point: a queued session is indistinguishable from a stopped one
  // on this field alone, which is what the pane used to decide on.
  running: false,
  checkoutId: 'worktree-1',
  checkoutKind: 'managed-worktree',
  setup: setup,
);

/// A RUNNING session with no tab yet — the shape `CheckoutReadiness.stalled`
/// reaches in practice: the checkout's `agent:status` never arrived, so there
/// is no per-terminal pull for a per-tab Retry to name.
SessionEntry _runningEntry() => SessionEntry(
  id: _sessionId,
  name: 'Fix auth bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  checkoutId: 'main',
  checkoutKind: 'main',
);

/// Records whether `retryAgentConnection` ran, without exercising its real
/// body — the real body reaches into the relay connection manager, which this
/// test's provider tree does not wire up.
class _SpyMachineConnectionNotifier extends MachineConnectionNotifier {
  bool retryAgentConnectionCalled = false;

  @override
  Future<void> retryAgentConnection() async {
    retryAgentConnectionCalled = true;
  }
}

/// Mounts the pane over a hand-seeded session list and a real per-project
/// session on a fake wire, so a press is asserted where it lands rather than
/// against a stub.
///
/// `terminalStateProvider` is overridden with an empty state: no tab means a
/// panel opened over it shows its empty log window rather than a live
/// terminal.
Future<FakeAgentTransport> pumpPane(
  WidgetTester tester,
  SessionSetup? setup, {
  Size? size,
  double textScale = 1,
}) => pumpPaneWith(
  tester,
  sessions: [_entry(setup)],
  activeId: _sessionId,
  size: size,
  textScale: textScale,
);

/// [pumpPane] with the inputs that pick WHICH state the pane is in.
/// [hangSession] never resolves the project, which is the bootstrap wait.
Future<FakeAgentTransport> pumpPaneWith(
  WidgetTester tester, {
  required List<SessionEntry> sessions,
  required String? activeId,
  CheckoutReadiness readiness = CheckoutReadiness.ready,
  bool hangSession = false,
  Size? size,
  double textScale = 1,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: _projectId,
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
  addTearDown(session.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        selectedRegistrationIdProvider.overrideWith((ref) => _projectId),
        projectSessionProvider(_projectId).overrideWith(
          (ref) => hangSession ? Completer<ProjectSession>().future : Future.value(session),
        ),
        activeSessionIdProvider.overrideWith(
          () => ValueController<String?>(activeId),
        ),
        freshSessionsStateProvider.overrideWithValue(
          SessionsState(projectId: _projectId, sessions: sessions),
        ),
        terminalStateProvider.overrideWith(
          (ref) => Stream.value(const TerminalState()),
        ),
        checkoutReadinessProvider.overrideWithValue(readiness),
      ],
      child: MaterialApp(
        builder: abToastHostBuilder,
        theme: ThemeData.dark().copyWith(
          extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: const Scaffold(body: TerminalScreen()),
          ),
        ),
      ),
    ),
  );
  // Two pumps: the project session and the terminal stream both resolve async.
  await tester.pump();
  await tester.pump();
  return transport;
}

/// The pane paints Carbon's background, not the terminal's: a pane that is
/// not the live terminal must not read as one.
void _expectCarbonBackdrop(WidgetTester tester, Finder inner) {
  final background = CarbonTheme.of(tester.element(inner)).colors.background;
  final colors = tester
      .widgetList<ColoredBox>(
        find.ancestor(of: inner, matching: find.byType(ColoredBox)),
      )
      .map((b) => b.color)
      .toList();
  expect(colors, contains(background));
  expect(colors, isNot(contains(kDefaultPalette.bgDeepest)));
}

/// Every Carbon scope on screen, none of which may build an Ab widget.
void _expectNoAbWidgets(WidgetTester tester) {
  final scopes = find.byType(AbCarbonScope);
  expect(scopes, findsWidgets);
  for (var i = 0; i < scopes.evaluate().length; i++) {
    expect(abWidgetsInScope(tester, scope: scopes.at(i)), isEmpty);
  }
}

Rect _rectOf(WidgetTester tester, String label) =>
    tester.getRect(find.widgetWithText(CarbonButton, label));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  testWidgets('a queued session is never called stopped', (tester) async {
    await pumpPane(tester, _setup(pendingStart: true));

    expect(find.text('Session stopped'), findsNothing);
    expect(find.text('Start'), findsNothing);
    expect(find.text('Start now'), findsOneWidget);
    // Cancel lives behind the strip's chevron, with the rest of the run.
    expect(find.text('Cancel setup'), findsNothing);
  });

  // The strip floating above carries everything about the run; the pane says
  // when the agent starts and offers the one way to hurry it, nothing else.
  testWidgets('the waiting pane is calm: a line and one button', (tester) async {
    await pumpPane(tester, _setup(pendingStart: true));

    expect(find.text('The agent starts when setup ends'), findsOneWidget);
    expect(find.byType(CarbonButton), findsOneWidget);
    expect(find.byType(SetupStepLedger), findsNothing);
    expect(find.byType(TerminalViewWrapper), findsNothing);
    expect(find.text('Waiting for workspace setup'), findsNothing);
    expect(find.text('Preparing workspace…'), findsNothing);
  });

  testWidgets('the empty and stopped states paint the Carbon background', (
    tester,
  ) async {
    await pumpPane(tester, _setup(pendingStart: false));
    _expectCarbonBackdrop(tester, find.text('Session stopped'));
    _expectNoAbWidgets(tester);
    // Has an icon, so a busy press swaps the glyph and keeps the label.
    expect(
      tester
          .widget<CarbonButton>(find.widgetWithText(CarbonButton, 'Start'))
          .icon,
      isA<CarbonIcon>().having((i) => i.icon, 'icon', CarbonIcons.play),
    );
  });

  testWidgets('a stopped chat offers Restart with the restart glyph', (
    tester,
  ) async {
    await pumpPaneWith(
      tester,
      sessions: [
        SessionEntry(
          id: _sessionId,
          name: 'Fix auth bug',
          createdAt: 0,
          lastUsedAt: 0,
          archived: false,
          running: false,
          mode: 'chat',
        ),
      ],
      activeId: _sessionId,
    );

    expect(find.text('Chat stopped'), findsOneWidget);
    _expectCarbonBackdrop(tester, find.text('Chat stopped'));
    expect(
      tester
          .widget<CarbonButton>(find.widgetWithText(CarbonButton, 'Restart'))
          .icon,
      isA<CarbonIcon>().having((i) => i.icon, 'icon', CarbonIcons.restart),
    );
  });

  testWidgets('with no session the pane says so on the Carbon background', (
    tester,
  ) async {
    await pumpPaneWith(tester, sessions: const [], activeId: null);

    expect(find.text('No active session'), findsOneWidget);
    expect(find.widgetWithText(CarbonButton, 'New session'), findsOneWidget);
    _expectCarbonBackdrop(tester, find.text('No active session'));
    _expectNoAbWidgets(tester);
  });

  testWidgets('the bootstrap wait is a small Carbon loading on Carbon ground', (
    tester,
  ) async {
    await pumpPaneWith(
      tester,
      sessions: const [],
      activeId: null,
      readiness: CheckoutReadiness.openingSession,
      hangSession: true,
    );

    expect(find.text('opening session'), findsOneWidget);
    final loading = tester.widget<CarbonLoading>(find.byType(CarbonLoading));
    expect(loading.size, CarbonLoadingSize.small);
    _expectCarbonBackdrop(tester, find.text('opening session'));
    _expectNoAbWidgets(tester);
  });

  testWidgets('the waiting pane is a Carbon surface', (tester) async {
    await pumpPane(tester, _setup(pendingStart: true));

    _expectCarbonBackdrop(
      tester,
      find.text('The agent starts when setup ends'),
    );
    _expectNoAbWidgets(tester);
    expect(find.byType(AbCarbonScope), findsOneWidget);
  });

  testWidgets('Start now is a tertiary play button centred in the pane', (
    tester,
  ) async {
    await pumpPane(tester, _setup(pendingStart: true));

    final start = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Start now'),
    );
    expect(start.kind, CarbonButtonKind.tertiary);
    expect(
      start.icon,
      isA<CarbonIcon>().having((i) => i.icon, 'icon', CarbonIcons.play),
    );
    final pane = tester.getRect(find.byType(TerminalScreen));
    final line = tester.getRect(find.text('The agent starts when setup ends'));
    final button = _rectOf(tester, 'Start now');
    expect(line.center.dx, closeTo(pane.center.dx, 1));
    expect(button.center.dx, closeTo(pane.center.dx, 1));
    expect(line.bottom, lessThanOrEqualTo(button.top));
  });

  testWidgets('the waiting pane does not overflow at 320x640 with 2x text', (
    tester,
  ) async {
    await pumpPane(
      tester,
      _setup(pendingStart: true),
      size: const Size(320, 640),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    final button = _rectOf(tester, 'Start now');
    expect(button.left, greaterThanOrEqualTo(0));
    expect(button.right, lessThanOrEqualTo(320));
  });

  testWidgets('a pending release shows busy on its button', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start now'));
    await tester.pump();

    final start = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Start now'),
    );
    expect(start.busy, isTrue);
    // Busy is not disabled: a null handler would paint the dimmed state.
    expect(start.onPressed, isNotNull);

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': true,
      'session': _entry(_setup(pendingStart: false)).toJson(),
    });
    await tester.pump();
  });

  // A second press while the first is unanswered must not put a second verb on
  // the wire: the run can only be ended once.
  testWidgets('a second press does not race the first', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start now'));
    await tester.pump();
    await tester.tap(find.text('Start now'));
    await tester.pump();
    await tester.pump();

    expect(
      transport.sent.where((m) => m['type'] == 'session:setup'),
      hasLength(1),
    );

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': true,
      'session': _entry(_setup(pendingStart: false)).toJson(),
    });
    await tester.pump();
  });

  // The gate is the ONLY thing this branch keys on. A session stopped for any
  // other reason — an explicit Stop, a crashed PTY — still owes the user the
  // button that respawns it.
  testWidgets('a genuinely stopped session still offers Start', (tester) async {
    await pumpPane(tester, _setup(pendingStart: false));

    expect(find.text('Session stopped'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Start now'), findsNothing);
  });

  // A shared session reports no setup at all, and must reach the same stopped
  // state as before this branch existed.
  testWidgets('a session with no setup is unaffected', (tester) async {
    await pumpPane(tester, null);

    expect(find.text('Session stopped'), findsOneWidget);
  });

  testWidgets('the release asks the bridge to skip the gate', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start now'));
    await tester.pump();
    await tester.pump();

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    expect(sent['sessionId'], _sessionId);
    expect(sent['action'], 'skip');

    // Answer it so nothing is left waiting on the reply timeout.
    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': true,
      'session': _entry(_setup(pendingStart: false)).toJson(),
    });
    await tester.pump();
  });

  // Nothing else on screen moves when a setup verb is refused, so a refusal
  // that only reached the log would be indistinguishable from a dropped press.
  testWidgets('a refusal is named rather than swallowed', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start now'));
    await tester.pump();
    await tester.pump();

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    transport.emit('session:result', {
      'requestId': sent['requestId'],
      'ok': false,
      'error': 'This isolated session is being deleted.',
    });
    await tester.pump();
    await tester.pump();

    expect(
      find.text(
        "Couldn't start the agent — This isolated session is being deleted.",
      ),
      findsOneWidget,
    );
  });

  group('with the setup strip', () {
    /// The whole agent panel over a resolved project, so the strip, its
    /// overlay position and the pane are all the production ones.
    Future<FakeAgentTransport> pumpPanel(
      WidgetTester tester,
      SessionEntry entry, {
      Size size = const Size(1000, 800),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final stores = await buildTestStoreOverrides();
      addTearDown(stores.close);
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      addTearDown(() => unawaited(session.close()));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...stores.overrides,
            selectedRegistrationIdProvider.overrideWith((ref) => _projectId),
            projectSessionProvider(
              _projectId,
            ).overrideWith((ref) async => session),
            activeSessionIdProvider.overrideWith(
              () => ValueController<String?>(_sessionId),
            ),
            freshSessionsStateProvider.overrideWithValue(
              SessionsState(projectId: _projectId, sessions: [entry]),
            ),
            terminalStateProvider.overrideWith(
              (ref) => Stream.value(const TerminalState()),
            ),
            checkoutReadinessProvider.overrideWithValue(
              CheckoutReadiness.ready,
            ),
          ],
          child: MaterialApp(
            builder: abToastHostBuilder,
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            home: const Scaffold(body: AgentPanel()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return transport;
    }

    SessionEntry runningEntry(SessionSetup? setup) => SessionEntry(
      id: _sessionId,
      name: 'Fix auth bug',
      createdAt: 0,
      lastUsedAt: 0,
      archived: false,
      running: true,
      checkoutId: 'worktree-1',
      checkoutKind: 'managed-worktree',
      setup: setup,
    );

    Finder button(String name) => find.byWidgetPredicate(
      (w) => w is CarbonButton && (w.label ?? w.semanticLabel) == name,
      description: 'CarbonButton "$name"',
    );

    // A height change on the terminal sends `terminal:resize`, so the strip
    // appearing, opening and going must not move the terminal at all.
    testWidgets('overlays the terminal area instead of pushing it down', (
      tester,
    ) async {
      await pumpPanel(tester, runningEntry(null));
      final bare = tester.getRect(find.byType(TerminalScreen));
      await tester.pumpWidget(const SizedBox.shrink());

      await pumpPanel(tester, runningEntry(_setup(pendingStart: false)));
      expect(find.byType(SetupElapsed), findsOneWidget);
      expect(tester.getRect(find.byType(TerminalScreen)), bare);
      // The strip sits on the terminal's top edge, inside its rect.
      expect(
        tester.getTopLeft(find.byType(SetupElapsed)).dy,
        inInclusiveRange(bare.top, bare.bottom),
      );

      await tester.tap(button('View setup details'));
      await tester.pump();
      expect(find.byType(SetupStepLedger), findsOneWidget);
      expect(tester.getRect(find.byType(TerminalScreen)), bare);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the waiting pane hides ledger and log until the chevron opens', (
      tester,
    ) async {
      final transport = await pumpPanel(
        tester,
        _entry(_setup(pendingStart: true)),
      );

      expect(button('Start now'), findsOneWidget);
      expect(find.byType(SetupStepLedger), findsNothing);
      expect(find.byType(TerminalViewWrapper), findsNothing);
      expect(find.text('Cancel setup'), findsNothing);
      // The strip is the only setup chrome above the pane.
      expect(find.byType(CarbonNotification), findsNothing);
      expect(
        find.text('Setting up workspace · 2 of 4 · Install dependencies'),
        findsOneWidget,
      );

      await tester.tap(button('View setup details'));
      await tester.pump();

      expect(find.byType(SetupStepLedger), findsOneWidget);
      expect(find.text('Copy env files'), findsOneWidget);
      expect(find.text('Build assets'), findsOneWidget);
      expect(find.text('Cancel setup'), findsOneWidget);
      // The open panel covers the pane's release, so it carries its own.
      final panelStart = find.descendant(
        of: find.byKey(const ValueKey('setup-panel')),
        matching: find.text('Start now'),
      );
      expect(button('Start now'), findsNWidgets(2));
      expect(panelStart, findsOneWidget);
      expect(panelStart.hitTestable(), findsOneWidget);

      await tester.tap(find.text('Cancel setup'));
      await tester.pump();
      await tester.pump();
      final sent = transport.sent.firstWhere(
        (m) => m['type'] == 'session:setup',
      );
      expect(sent['action'], 'cancel');
      transport.emit('session:result', {
        'requestId': sent['requestId'],
        'ok': true,
        'session': _entry(_setup(pendingStart: false)).toJson(),
      });
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    // Both verbs end the same wait; the panel's release and cancel share one
    // in-flight slot. The release is tapped through the panel, the only copy
    // an open panel leaves hit-testable.
    testWidgets('a cancel in flight keeps the release from racing it', (
      tester,
    ) async {
      final transport = await pumpPanel(
        tester,
        _entry(_setup(pendingStart: true)),
      );
      await tester.tap(button('View setup details'));
      await tester.pump();

      final release = find.descendant(
        of: find.byKey(const ValueKey('setup-panel')),
        matching: find.text('Start now'),
      );
      expect(release.hitTestable(), findsOneWidget);

      await tester.tap(find.text('Cancel setup'));
      await tester.pump();
      await tester.tap(release);
      await tester.pump();
      await tester.pump();

      final sent = transport.sent
          .where((m) => m['type'] == 'session:setup')
          .toList();
      expect(sent, hasLength(1));
      expect(sent.single['action'], 'cancel');

      transport.emit('session:result', {
        'requestId': sent.single['requestId'],
        'ok': true,
        'session': _entry(_setup(pendingStart: false)).toJson(),
      });
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // On a local target `retryAgentConnection` opens with
  // `if (target == null || target.isLocal) return;`, so routing this Retry
  // through it paints a button that provably cannot act. Stalled is only
  // reachable with the session already resolved, so re-establishing the
  // machine connection is the wrong lever on a remote target too.
  testWidgets(
    "a stalled checkout's Retry drives the checkout re-attach, not the "
    'machine reconnect',
    (tester) async {
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      // Not awaited: close() flushes CachedSessionsStore through
      // SharedPreferencesAsync, and awaiting that real I/O inside
      // testWidgets' fake-async zone wedges teardown with no timeout (see
      // terminal_list_view_empty_state_test.dart). The timer this test cares
      // about is retired directly below instead.
      addTearDown(() => unawaited(session.close()));
      final spy = _SpyMachineConnectionNotifier();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            selectedRegistrationIdProvider.overrideWith((ref) => _projectId),
            projectSessionProvider(
              _projectId,
            ).overrideWith((ref) async => session),
            activeSessionIdProvider.overrideWith(
              () => ValueController<String?>(_sessionId),
            ),
            freshSessionsStateProvider.overrideWithValue(
              SessionsState(projectId: _projectId, sessions: [_runningEntry()]),
            ),
            // No tab has arrived — the shape a checkout stuck attaching
            // actually produces. Decoupled from the real per-project
            // TerminalService the widget resolves, which is what lets this
            // pin that service's own state below rather than a stub's.
            terminalStateProvider.overrideWith(
              (ref) => Stream.value(const TerminalState()),
            ),
            checkoutReadinessProvider.overrideWithValue(
              CheckoutReadiness.stalled,
            ),
            machineConnectionProvider.overrideWith(() => spy),
          ],
          child: MaterialApp(
            builder: abToastHostBuilder,
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
            ),
            home: const Scaffold(body: TerminalScreen()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text("couldn't reach the agent"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      _expectCarbonBackdrop(tester, find.text("couldn't reach the agent"));
      _expectNoAbWidgets(tester);
      expect(find.byType(CarbonStatusIcon), findsOneWidget);

      final terminalService = session.servicesForCheckout('main').terminalService;
      // Nothing has subscribed to the real service's own stream (the pane
      // reads the stubbed `terminalStateProvider` above), so its attach
      // verdict is still the constructor default — this is what proves the
      // change below came from the tap, not from bootstrap.
      expect(terminalService.currentState.attach, CheckoutAttachStatus.unknown);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(
        terminalService.currentState.attach,
        CheckoutAttachStatus.attaching,
        reason: 'retryCheckoutAttach ran on the real per-project service',
      );
      expect(spy.retryAgentConnectionCalled, isFalse);

      // No pending timer to retire: nothing subscribes to the real service's
      // stream here, and the checkout bound is armed only over a live one.
    },
  );
}
