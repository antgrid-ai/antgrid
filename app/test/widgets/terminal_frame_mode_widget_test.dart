// Widget-layer coverage for Wave 7's live frame-replace terminal protocol.
// The service half (terminal_service.dart) owns the protocol state machine
// and its own opt-in suite (test/services/terminal_frame_mode_test.dart);
// this file owns what TerminalViewWrapper does with that state:
//
//   - D7: TerminalAttachStage.ended's chrome (an exhaustive switch, so this
//     is the only place that stage's rendering is pinned) and the frame
//     protocol's own display:status message winning over the generic label.
//   - D10: an applied frame clears a live selection mirror rather than
//     leaving it pointed at glyphs the frame just replaced.
//   - (g): the load a live frame stream (up to 20/s) adds to the widget
//     tree, measured directly rather than argued.
//   - (d): mouse tracking and DEC 1004 focus reporting read the engine's
//     OWN mode state, which a frame's preamble sets exactly the way legacy
//     output does — proven at the controller the wrapper drives, since
//     neither is called from the wrapper itself.
//
// None of this depends on how a tab REACHES frame mode: every tab built here
// is passed `mode: TerminalDisplayMode.frame` explicitly, so the file tests
// the display contract alone and stays valid whatever selects the mode.

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/send_to_agent_button.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/prefs_test_mock.dart';

bool _hasNative() {
  try {
    GhosttyVt.newTerminal(cols: 8, rows: 2).close();
    return true;
  } catch (_) {
    return false;
  }
}

/// True when the native VT is missing, having marked the current test
/// skipped — same convention as terminal_frame_mode_test.dart and
/// terminal_frame_prototype_test.dart.
bool _skipWithoutNative() {
  if (_hasNative()) return false;
  markTestSkipped('native VT unavailable');
  return true;
}

late SharedPreferencesWithCache _settingsPrefs;
const _myClientId = 'this-install';

/// Mirrors terminal_hydration_overlay_test.dart's `_makeService` — a real
/// (local) ProjectSession + TerminalService over a FakeAgentTransport. Only
/// used where a genuine TerminalService is needed at all; most cases here
/// only exercise the widget's own reaction to hydration/tab state.
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

/// A frame-mode tab, built directly (not through TerminalService) so its
/// TerminalDisplayMode.frame is explicit rather than reached by driving the
/// subscribe handshake — the state machine that gets there is the service
/// half's own suite; this file only needs the tab already committed to it.
TerminalTab _tab({
  required String id,
  String? type = 'service',
}) {
  final tab = TerminalTab(
    terminalId: id,
    name: id,
    sessionState: TerminalSessionState.running,
    type: type,
    cols: 80,
    rows: 24,
    mode: TerminalDisplayMode.frame,
  );
  tab.ghostty.attachExternalTransport(writeBytes: (_) => true);
  // Never enters TerminalService's own tab map, so nothing else disposes it.
  addTearDown(() async => tab.ghostty.dispose());
  return tab;
}

TerminalState _stateWith({Map<String, TerminalHydration> hydration = const {}}) =>
    TerminalState(hydration: hydration);

/// Wraps [child] with the providers TerminalViewWrapper reads, mirroring
/// terminal_hydration_overlay_test.dart's `_wrap`.
Widget _wrap(
  Widget child, {
  required Stream<TerminalState> terminalState,
  TerminalTab? agentTab,
  Key? key,
}) => ProviderScope(
  key: key,
  overrides: [
    clientIdProvider.overrideWith((ref) => Future.value(_myClientId)),
    agentTerminalProvider.overrideWith((ref) => agentTab),
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    useInMemoryPrefs();
    _settingsPrefs = await openAppSettingsPrefs();
  });

  group('D7: TerminalAttachStage.ended chrome', () {
    testWidgets(
      'renders the protocol\'s own message, undimmed, with no Retry',
      (tester) async {
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
                    stage: TerminalAttachStage.ended,
                    message: 'the run completed',
                  ),
                },
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('the run completed'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
        expect(
          find.ancestor(
            of: find.byType(GhosttyTerminalView),
            matching: find.byWidgetPredicate((w) => w is Opacity),
          ),
          findsNothing,
          reason: 'ended must never dim the screen — it is a real final '
              'state, not a wait or a failure',
        );
      },
    );

    testWidgets('falls back to a generic label when the protocol sent none', (
      tester,
    ) async {
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
                  stage: TerminalAttachStage.ended,
                ),
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('this session has ended'), findsOneWidget);
    });
  });

  group('D7: the failed chrome prefers the protocol\'s own message', () {
    testWidgets('a display:status message replaces the generic label', (
      tester,
    ) async {
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
                  message: 'could not render',
                ),
              },
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('could not render'), findsOneWidget);
      // The pre-existing generic copy, still reachable, must not show
      // alongside the protocol's own reason.
      expect(find.text("couldn't load this terminal"), findsNothing);
    });
  });

  group('D10: an applied frame clears a live selection mirror', () {
    testWidgets(
      'SendToAgentButton disappears once TerminalTab.replaceEpoch bumps',
      (tester) async {
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1', type: 'agent');

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
            terminalState: Stream.value(_stateWith()),
            agentTab: tab,
          ),
        );
        await tester.pump();
        expect(find.byType(SendToAgentButton), findsNothing);

        // Simulates the engine reporting a live selection — the same
        // callback GhosttyTerminalView invokes for a real drag-select, fired
        // directly so this needs no native VT.
        final view = tester.widget<GhosttyTerminalView>(
          find.byType(GhosttyTerminalView),
        );
        view.onSelectionContentChanged!(
          const GhosttyTerminalSelectionContent(
            selection: GhosttyTerminalSelection(
              base: GhosttyTerminalCellPosition(row: 0, col: 0),
              extent: GhosttyTerminalCellPosition(row: 0, col: 4),
            ),
            text: 'hello',
          ),
        );
        await tester.pump();
        expect(
          find.byType(SendToAgentButton),
          findsOneWidget,
          reason: 'a live selection must show the button before any frame '
              'invalidates it — otherwise the frame-replace assertion below '
              'proves nothing',
        );

        // The signal TerminalService._handleTerminalFrame sends on every
        // applied frame (D10) — the screen under the selection's row/col
        // anchors was just replaced wholesale.
        tab.replaceEpoch.value++;
        await tester.pump();

        expect(find.byType(SendToAgentButton), findsNothing);
      },
    );

    testWidgets(
      'the engine re-reporting the SAME anchors cannot repopulate the mirror '
      'after a frame replaced the glyphs under them',
      (tester) async {
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1', type: 'agent');

        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 300,
              height: 400,
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
            ),
            terminalState: Stream.value(_stateWith()),
            agentTab: tab,
          ),
        );
        await tester.pump();

        final view = tester.widget<GhosttyTerminalView>(
          find.byType(GhosttyTerminalView),
        );
        const anchors = GhosttyTerminalSelection(
          base: GhosttyTerminalCellPosition(row: 0, col: 0),
          extent: GhosttyTerminalCellPosition(row: 0, col: 4),
        );
        view.onSelectionContentChanged!(
          const GhosttyTerminalSelectionContent(
            selection: anchors,
            text: 'hello',
          ),
        );
        await tester.pump();
        expect(find.byType(SendToAgentButton), findsOneWidget);

        tab.replaceEpoch.value++;
        await tester.pump();
        expect(find.byType(SendToAgentButton), findsNothing);

        // GhosttyTerminalView re-resolves its selection's text and fires this
        // callback on EVERY controller notify while it holds a selection, and
        // nothing in the view clears anchors a frame invalidated. A resize, a
        // setSessionRunning, or a focus assertion is enough -- and the text it
        // re-reports is whatever the frame put at those cells.
        view.onSelectionContentChanged!(
          const GhosttyTerminalSelectionContent(
            selection: anchors,
            text: 'rm -rf / --no-preserve-root',
          ),
        );
        await tester.pump();

        expect(
          find.byType(SendToAgentButton),
          findsNothing,
          reason: 'Ctrl+C and SendToAgentButton both read the mirror, and '
              'handing the user glyphs they never selected is the harm D10 '
              'exists to prevent',
        );
      },
    );

    testWidgets('a genuinely new selection after a frame re-arms the mirror', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1', type: 'agent');

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
          terminalState: Stream.value(_stateWith()),
          agentTab: tab,
        ),
      );
      await tester.pump();

      final view = tester.widget<GhosttyTerminalView>(
        find.byType(GhosttyTerminalView),
      );
      view.onSelectionContentChanged!(
        const GhosttyTerminalSelectionContent(
          selection: GhosttyTerminalSelection(
            base: GhosttyTerminalCellPosition(row: 0, col: 0),
            extent: GhosttyTerminalCellPosition(row: 0, col: 4),
          ),
          text: 'hello',
        ),
      );
      await tester.pump();
      tab.replaceEpoch.value++;
      await tester.pump();
      expect(find.byType(SendToAgentButton), findsNothing);

      // Refusing the invalidated anchors must not deafen the wrapper: the
      // user's next drag produces different anchors and has to arm again.
      view.onSelectionContentChanged!(
        const GhosttyTerminalSelectionContent(
          selection: GhosttyTerminalSelection(
            base: GhosttyTerminalCellPosition(row: 2, col: 1),
            extent: GhosttyTerminalCellPosition(row: 2, col: 9),
          ),
          text: 'chosen by hand',
        ),
      );
      await tester.pump();

      expect(find.byType(SendToAgentButton), findsOneWidget);
    });

    testWidgets('a bump with no live selection is a no-op', (tester) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1', type: 'agent');

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
          terminalState: Stream.value(_stateWith()),
          agentTab: tab,
        ),
      );
      await tester.pump();

      tab.replaceEpoch.value++;
      await tester.pump();

      expect(find.byType(SendToAgentButton), findsNothing);
    });
  });

  group('(g): a live frame stream does not force a widget rebuild', () {
    testWidgets(
      'a burst of replaceEpoch bumps with nothing selected never rebuilds '
      'or remounts the engine element',
      (tester) async {
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1');

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
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();
        final before = tester.element(find.byType(GhosttyTerminalView));

        // Stands in for ~2s of a 20fps frame stream (TERMINAL_FRAME_INTERVAL_MS)
        // with nothing selected — the steady-state case, and the one a
        // careless listener would turn into a LayoutBuilder re-run per frame
        // (see _TerminalGridFreeze's own doc comment on why that regresses
        // the exact failure it was built to fix).
        for (var i = 0; i < 40; i++) {
          tab.replaceEpoch.value++;
        }
        await tester.pump();

        final after = tester.element(find.byType(GhosttyTerminalView));
        expect(
          identical(before, after),
          isTrue,
          reason: 'TerminalService never calls _setState for an applied '
              'frame, and the widget\'s own replaceEpoch listener is a '
              'no-op with no live selection — nothing here should have '
              'walked this subtree at all',
        );
      },
    );
  });

  // (d): TerminalViewWrapper calls neither sendMouse nor setFocused itself —
  // GhosttyTerminalView's own gesture layer and TerminalService's focus
  // coordinator do, both against widget.tab.ghostty directly — so this
  // exercises the controller the wrapper drives rather than the wrapper's
  // own build method. What it proves is the mechanism the wrapper's
  // correctness actually rests on: a frame is one appendOutputBytes call
  // through the SAME VT parser legacy output uses (D3), and mouse/focus
  // mode state is read fresh off that parser on every call — so a frame
  // that turns a mode on or off is exactly as effective as the guest
  // sending it directly ever was.
  group('(d): mouse tracking and DEC 1004 focus reporting read the frame\'s '
      'own mode state', () {
    test(
      'sendMouse reports nothing before a frame enables tracking, and a '
      'report after',
      () {
        if (_skipWithoutNative()) return;
        final controller = GhosttyTerminalController();
        addTearDown(controller.dispose);
        final sent = <int>[];
        controller.attachExternalTransport(
          writeBytes: (b) {
            sent.addAll(b);
            return true;
          },
        );

        // Establishes the engine with no mouse mode set yet — plain guest
        // output, exactly as a frame's own serialized rows would if the
        // guest had never asked for mouse tracking.
        controller.appendOutputBytes('hello'.codeUnits);

        const size = VtMouseEncoderSize(
          screenWidth: 800,
          screenHeight: 600,
          cellWidth: 10,
          cellHeight: 20,
        );
        controller.sendMouse(
          action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
          button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
          position: const VtMousePosition(x: 10, y: 10),
          size: size,
        );
        expect(sent, isEmpty);

        // The exact shape TerminalModeTracker.supplementalPrelude() appends
        // after every frame body (bridge/src/terminal-modes.ts): one
        // `\x1b[?<mode>h` per latched mode, concatenated with no separator.
        controller.appendOutputBytes('\x1b[?1000h\x1b[?1006h'.codeUnits);

        controller.sendMouse(
          action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
          button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
          position: const VtMousePosition(x: 10, y: 10),
          size: size,
        );
        expect(sent, isNotEmpty);
      },
    );

    test(
      'DEC 1004 focus reporting re-asserts against a mode a frame just '
      'turned on',
      () {
        if (_skipWithoutNative()) return;
        final controller = GhosttyTerminalController();
        addTearDown(controller.dispose);
        final sent = <int>[];
        controller.attachExternalTransport(
          writeBytes: (b) {
            sent.addAll(b);
            return true;
          },
        );

        // Host focus intent latched BEFORE the guest has asked for reports —
        // exactly TerminalService._createTab's own ordering (setFocused is
        // called once at tab creation, before any output has arrived).
        controller.setFocused(true);
        expect(sent, isEmpty);

        // A frame whose own preamble enables 1004 (the guest asked for focus
        // reports at startup, same as legacy) re-asserts the latched intent
        // on ingest — TerminalController._ingestBytes calls
        // _flushFocusReport() after every appendOutputBytes, frame or not.
        controller.appendOutputBytes('\x1b[?1004h'.codeUnits);
        expect(String.fromCharCodes(sent), '\x1b[I');
      },
    );
  });
}
