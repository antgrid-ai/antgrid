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
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/prefs_test_mock.dart';
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
/// `terminalStateProvider` is overridden with an empty state: no tab means the
/// pane takes its transcript-less arm, which is the state a run reaches before
/// it has reported the PTY it spawned — and the one every assertion here is
/// about. The transcript arm is the banner's own `_buildLog` widget.
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
    expect(find.text('Preparing workspace…'), findsOneWidget);
    expect(find.text('Start agent now'), findsOneWidget);
    // The bridge has accepted `cancel` since the verb shipped and no surface
    // offered it; this pane is the one that does.
    expect(find.text('Cancel setup'), findsOneWidget);
  });

  // The pane is what the user stares at for the whole run, so it is where the
  // ledger belongs: "2 of 4" says how far along the run is and nothing about
  // what is left, which on a real block is the question being asked.
  testWidgets('the pane says what is still to come', (tester) async {
    await pumpPane(tester, _setup(pendingStart: true));

    expect(find.text('Copy env files'), findsOneWidget);
    expect(find.text('Generate client'), findsOneWidget);
    expect(find.text('Build assets'), findsOneWidget);
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

  testWidgets('the preparing state and its action bar are Carbon surfaces', (
    tester,
  ) async {
    await pumpPane(tester, _setup(pendingStart: true));

    _expectCarbonBackdrop(tester, find.text('Preparing workspace…'));
    _expectNoAbWidgets(tester);
    // Three islands (ledger, empty state, action bar), none of them around a
    // live terminal.
    expect(find.byType(AbCarbonScope), findsNWidgets(3));
  });

  testWidgets('the action bar pairs a secondary Cancel before a primary Start', (
    tester,
  ) async {
    await pumpPane(tester, _setup(pendingStart: true));

    final cancel = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Cancel setup'),
    );
    final start = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Start agent now'),
    );
    expect(cancel.kind, CarbonButtonKind.secondary);
    expect(start.kind, CarbonButtonKind.primary);

    // Wide enough to sit side by side, in reading order.
    final c = _rectOf(tester, 'Cancel setup');
    final st = _rectOf(tester, 'Start agent now');
    expect(c.right, lessThanOrEqualTo(st.left + 1));
    expect(c.top, closeTo(st.top, 0.5));
  });

  testWidgets("a wide action bar keeps its label on the buttons' row", (
    tester,
  ) async {
    await pumpPane(
      tester,
      _setup(pendingStart: true),
      size: const Size(1400, 900),
    );

    // Every line this bar takes comes out of the terminal above it.
    final label = tester.getRect(find.text('Waiting for workspace setup'));
    final st = _rectOf(tester, 'Start agent now');
    expect(label.center.dy, inInclusiveRange(st.top, st.bottom));
    expect(label.right, lessThanOrEqualTo(_rectOf(tester, 'Cancel setup').left));
  });

  testWidgets('the action bar stacks at 320 wide with 2x text, no overflow', (
    tester,
  ) async {
    await pumpPane(
      tester,
      _setup(pendingStart: true),
      size: const Size(320, 900),
      textScale: 2,
    );

    expect(tester.takeException(), isNull);
    final c = _rectOf(tester, 'Cancel setup');
    final st = _rectOf(tester, 'Start agent now');
    // Stacked with the primary on top, each spanning the bar.
    expect(st.bottom, lessThanOrEqualTo(c.top + 1));
    expect(st.width, closeTo(c.width, 0.5));
    expect(st.right, lessThanOrEqualTo(320));
    expect(c.left, greaterThanOrEqualTo(0));
  });

  testWidgets('a pending release shows busy on its own button only', (
    tester,
  ) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start agent now'));
    await tester.pump();

    final start = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Start agent now'),
    );
    final cancel = tester.widget<CarbonButton>(
      find.widgetWithText(CarbonButton, 'Cancel setup'),
    );
    expect(start.busy, isTrue);
    // Busy is not disabled: a null handler would paint the dimmed state.
    expect(start.onPressed, isNotNull);
    expect(cancel.busy, isFalse);
    // The two verbs are alternatives, so the other one is inert meanwhile.
    expect(cancel.onPressed, isNull);
    expect(
      find.ancestor(
        of: find.text('Start agent now'),
        matching: find.byWidgetPredicate((w) => w is Visibility && !w.visible),
      ),
      findsNothing,
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
    expect(find.text('Start agent now'), findsNothing);
  });

  // A shared session reports no setup at all, and must reach the same stopped
  // state as before this branch existed.
  testWidgets('a session with no setup is unaffected', (tester) async {
    await pumpPane(tester, null);

    expect(find.text('Session stopped'), findsOneWidget);
  });

  testWidgets('the release asks the bridge to skip the gate', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Start agent now'));
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

  testWidgets('cancelling asks the bridge to stop the run', (tester) async {
    final transport = await pumpPane(tester, _setup(pendingStart: true));

    await tester.tap(find.text('Cancel setup'));
    await tester.pump();
    await tester.pump();

    final sent = transport.sent.firstWhere((m) => m['type'] == 'session:setup');
    expect(sent['action'], 'cancel');

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

    await tester.tap(find.text('Start agent now'));
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
