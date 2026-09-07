// TerminalViewWrapper's pane chrome, driven entirely by a stubbed
// terminalStateProvider so every TerminalAttachStage (plus inputPaused and
// the no-hydration-yet state) can be forced without driving the real
// snapshot/status protocol. `retryAttach` reachability is the one case that
// needs a live TerminalService, so it feeds a real `agent:status` through
// FakeAgentTransport to register the tab the button retries.
//
// Never pumpAndSettle here: `attaching to terminal` mounts a TerminalElapsed,
// which owns a 1s Timer.periodic that setState()s on every tick and so never
// lets pumpAndSettle's frame-quiescence check succeed.

import 'dart:async';

import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/terminal_hydration_strip.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/prefs_test_mock.dart';

late SharedPreferencesWithCache _settingsPrefs;

const _myClientId = 'this-install';
const _otherClientId = 'some-other-device';

/// Real (local) [ProjectSession] + [TerminalService] over a
/// [FakeAgentTransport], for the one case that needs a genuine `retryAttach`
/// rather than a stubbed strip. Mirrors `terminal_letterbox_test.dart`'s
/// `_makeService`.
Future<({TerminalService service, FakeAgentTransport transport})> _makeService(
  void Function(Future<void> Function()) registerTearDown,
) async {
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'p',
    transport: transport,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => await transport.dispose(),
  );
  final service = TerminalService.fromSession(session);
  registerTearDown(() async {
    await service.dispose();
    await session.close();
  });
  return (service: service, transport: transport);
}

TerminalTab _tab({
  required String id,
  int cols = 80,
  String? driverClientId,
}) {
  final tab = TerminalTab(
    terminalId: id,
    name: id,
    sessionState: TerminalSessionState.running,
    type: 'service',
    cols: cols,
    rows: 24,
    driverClientId: driverClientId,
  );
  tab.ghostty.attachExternalTransport(writeBytes: (_) => true);
  // Never enters TerminalService's own tab map, so nothing else disposes it.
  addTearDown(() async => tab.ghostty.dispose());
  return tab;
}

TerminalState _stateWith({
  Map<String, TerminalHydration> hydration = const {},
  bool inputPaused = false,
}) => TerminalState(hydration: hydration, inputPaused: inputPaused);

/// Wraps [child] with the providers `TerminalViewWrapper` reads, pinning
/// `terminalStateProvider` to [terminalState] so a stage/inputPaused
/// combination can be forced without driving the real protocol.
Widget _wrap(
  Widget child, {
  required Stream<TerminalState> terminalState,
  Key? key,
}) => ProviderScope(
  key: key,
  overrides: [
    clientIdProvider.overrideWith((ref) => Future.value(_myClientId)),
    // _buildTerminal watches agentTerminalProvider for the send-to-agent
    // overlay; these tabs are not the agent, so pin it null to keep the
    // throwing focused-session façades out of the test.
    agentTerminalProvider.overrideWith((ref) => null),
    appSettingsServiceProvider.overrideWith(
      () => AppSettingsService(
        _settingsPrefs,
        AppSettings.fromPrefs(_settingsPrefs),
      ),
    ),
    terminalStateProvider.overrideWith((ref) => terminalState),
  ],
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    home: Scaffold(body: child),
  ),
);

/// A [GhosttyTerminalView] with an [Opacity] ancestor at exactly
/// `AbTokens.opacityDisabled` — the de-emphasis applied to an unpainted engine.
Finder get _dimmedTerminal => find.ancestor(
  of: find.byType(GhosttyTerminalView),
  matching: find.byWidgetPredicate(
    (w) => w is Opacity && w.opacity == AbTokens.opacityDisabled,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    useInMemoryPrefs();
    _settingsPrefs = await openAppSettingsPrefs();
  });

  testWidgets('cold and awaitingScreen render the attaching strip, dimmed', (
    tester,
  ) async {
    final h = await _makeService(addTearDown);
    final tab = _tab(id: 't1');

    for (final stage in [
      TerminalAttachStage.cold,
      TerminalAttachStage.awaitingScreen,
    ]) {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
          terminalState: Stream.value(
            _stateWith(
              hydration: {
                't1': TerminalHydration(stage: stage, requestedAtMs: 1000),
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('attaching to terminal'),
        findsOneWidget,
        reason: 'stage $stage',
      );
      expect(_dimmedTerminal, findsOneWidget, reason: 'stage $stage');
      // No Retry at this stage: the deadline hasn't fired yet.
      expect(find.text('Retry'), findsNothing, reason: 'stage $stage');
    }
  });

  testWidgets('failed renders a danger strip with a Retry that reaches '
      'retryAttach', (tester) async {
    final h = await _makeService(addTearDown);
    final tab = _tab(id: 't1');

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 300,
          height: 400,
          child: TerminalViewWrapper(tab: tab, terminalService: h.service),
        ),
        terminalState: Stream.value(
          _stateWith(
            hydration: {
              't1': const TerminalHydration(
                stage: TerminalAttachStage.failed,
              ),
            },
          ),
        ),
      ),
    );
    await tester.pump();

    // Registers 't1' in the SERVICE's own tab map (not the stubbed
    // TerminalState the widget reads its chrome from) so `retryAttach` finds
    // it live rather than bailing on `!_state.tabs.containsKey`.
    h.transport.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {'id': 't1', 'terminalId': 't1', 'name': 't1', 'running': true},
      ],
    });
    await tester.pump();
    h.transport.sent.clear();

    expect(find.text("couldn't load this terminal"), findsOneWidget);
    expect(_dimmedTerminal, findsOneWidget);
    final retry = find.widgetWithText(AbButton, 'Retry');
    expect(retry, findsOneWidget);

    await tester.tap(retry);
    await tester.pump();

    final requests = h.transport.sent
        .where((m) => m['type'] == 'terminal:snapshot:request')
        .toList();
    expect(requests, hasLength(1));
    expect(requests.single['terminalId'], 't1');

    // The retry arms a fresh snapshot deadline, and the binding checks for a
    // pending timer BEFORE any tearDown runs. Retired by letting it expire,
    // not by disposing here: dispose() awaits real stream cancellations, and
    // awaiting real async inside a testWidgets body wedges with no timeout.
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets(
    'refreshing and painted render no strip and never dim the terminal',
    (tester) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');

      for (final stage in [
        TerminalAttachStage.refreshing,
        TerminalAttachStage.painted,
      ]) {
        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 300,
              height: 400,
              child: TerminalViewWrapper(
                tab: tab,
                terminalService: h.service,
              ),
            ),
            terminalState: Stream.value(
              _stateWith(
                hydration: {
                  't1': TerminalHydration(stage: stage, requestedAtMs: 1000),
                },
              ),
            ),
          ),
        );
        await tester.pump();

        expect(
          find.byType(TerminalHydrationStrip),
          findsNothing,
          reason: 'stage $stage',
        );
        expect(_dimmedTerminal, findsNothing, reason: 'stage $stage');
      }
    },
  );

  testWidgets('a missing hydration entry renders no strip', (tester) async {
    final h = await _makeService(addTearDown);
    final tab = _tab(id: 't1');

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 300,
          height: 400,
          child: TerminalViewWrapper(tab: tab, terminalService: h.service),
        ),
        // No 't1' key at all — the state before this terminal's first
        // _setState, or an unkeyed mount reusing this State mid-swap.
        terminalState: Stream.value(_stateWith()),
      ),
    );
    await tester.pump();

    expect(find.byType(TerminalHydrationStrip), findsNothing);
    expect(_dimmedTerminal, findsNothing);
  });

  testWidgets("inputPaused wins over the stage's own copy", (tester) async {
    final h = await _makeService(addTearDown);
    final tab = _tab(id: 't1');

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 300,
          height: 400,
          child: TerminalViewWrapper(tab: tab, terminalService: h.service),
        ),
        terminalState: Stream.value(
          _stateWith(
            // painted would otherwise render nothing at all — proving the
            // input-paused strip is not merely reachable but wins outright.
            hydration: {
              't1': const TerminalHydration(
                stage: TerminalAttachStage.painted,
              ),
            },
            inputPaused: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('reconnecting — input paused'), findsOneWidget);
    expect(find.text('attaching to terminal'), findsNothing);
    expect(find.text("couldn't load this terminal"), findsNothing);
    // inputPaused says nothing about the paint, so it must not dim a screen
    // that stage alone would leave undimmed.
    expect(_dimmedTerminal, findsNothing);
  });

  testWidgets(
    'the strip does not move the authoritative grid — the driver fills the '
    'remainder, short by exactly the strip height',
    (tester) async {
      final h = await _makeService(addTearDown);

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(
              tab: _tab(id: 'no-strip'),
              terminalService: h.service,
            ),
          ),
          terminalState: Stream.value(_stateWith()),
          key: const ValueKey('no-strip'),
        ),
      );
      await tester.pump();
      final withoutStrip = tester.getSize(find.byType(GhosttyTerminalView));

      // A distinct scope key so the second pump builds a fresh container and
      // a fresh grid freeze, rather than reconciling onto the first one and
      // holding its pinned box.
      await tester.pumpWidget(
        _wrap(
          key: const ValueKey('with-strip'),
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(
              tab: _tab(id: 'with-strip'),
              terminalService: h.service,
            ),
          ),
          terminalState: Stream.value(
            _stateWith(
              hydration: {
                'with-strip': const TerminalHydration(
                  stage: TerminalAttachStage.cold,
                ),
              },
            ),
          ),
        ),
      );
      await tester.pump();
      // The stubbed state arrives over a microtask, and the grid freeze holds
      // its first pinned box until the settle window elapses — measuring
      // before both would compare the strip against a stale terminal.
      await tester.pump(const Duration(milliseconds: 200));
      final stripHeight = tester
          .getSize(find.byType(TerminalHydrationStrip))
          .height;
      final withStrip = tester.getSize(find.byType(GhosttyTerminalView));

      expect(withStrip.width, withoutStrip.width);
      expect(
        withoutStrip.height - withStrip.height,
        closeTo(stripHeight, 0.5),
      );
    },
  );

  testWidgets('the dim reaches the non-driver (letterbox) arm too', (
    tester,
  ) async {
    final h = await _makeService(addTearDown);
    // Driven by another device → non-driver FittedBox/letterbox arm.
    final tab = _tab(id: 't1', cols: 40, driverClientId: _otherClientId);

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 300,
          height: 400,
          child: TerminalViewWrapper(tab: tab, terminalService: h.service),
        ),
        terminalState: Stream.value(
          _stateWith(
            hydration: {
              't1': const TerminalHydration(stage: TerminalAttachStage.cold),
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(FittedBox), findsOneWidget);
    expect(
      find.descendant(of: find.byType(FittedBox), matching: _dimmedTerminal),
      findsOneWidget,
    );
  });

  testWidgets('a hydration transition does not remount the engine', (
    tester,
  ) async {
    final h = await _makeService(addTearDown);
    final tab = _tab(id: 't1');
    final controller = StreamController<TerminalState>.broadcast();
    addTearDown(controller.close);

    Widget host() => _wrap(
      SizedBox(
        width: 300,
        height: 400,
        child: TerminalViewWrapper(tab: tab, terminalService: h.service),
      ),
      terminalState: controller.stream,
    );

    // Mount first — a broadcast controller drops anything added before it has
    // a listener, and the provider only subscribes once this build watches it.
    await tester.pumpWidget(host());
    controller.add(
      _stateWith(
        hydration: {
          't1': const TerminalHydration(stage: TerminalAttachStage.cold),
        },
      ),
    );
    await tester.pump();
    expect(find.text('attaching to terminal'), findsOneWidget);
    final before = tester.element(find.byType(GhosttyTerminalView));

    controller.add(
      _stateWith(
        hydration: {
          't1': const TerminalHydration(stage: TerminalAttachStage.painted),
        },
      ),
    );
    await tester.pump();
    expect(find.text('attaching to terminal'), findsNothing);
    final after = tester.element(find.byType(GhosttyTerminalView));

    expect(identical(before, after), isTrue);
  });
}
