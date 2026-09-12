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
//   - the scrollback that frame mode moved out of the engine: the dead
//     scrollbar it removes, and the two ways (a clamped scroll, a pinned
//     control) the reader over the live pane is reached and dismissed.
//   - (d): mouse tracking and DEC 1004 focus reporting read the engine's
//     OWN mode state, which a frame's preamble sets exactly the way legacy
//     output does — proven at the controller the wrapper drives, since
//     neither is called from the wrapper itself.
//
// None of this depends on how a tab REACHES frame mode: every tab built here
// is passed `mode: TerminalDisplayMode.frame` explicitly, so the file tests
// the display contract alone and stays valid whatever selects the mode.

import 'dart:async';
import 'dart:convert';

import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_button.dart';
import 'package:antgrid/design/widgets/ab_empty_state.dart';
import 'package:antgrid/design/widgets/ab_icon_button.dart';
import 'package:antgrid/models/ab_message.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/services/upload_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/clipboard_image.dart';
import 'package:antgrid/widgets/send_to_agent_button.dart';
import 'package:antgrid/widgets/terminal_drop_target.dart';
import 'package:antgrid/widgets/terminal_history_view.dart';
import 'package:antgrid/widgets/terminal_quick_actions_bar.dart';
import 'package:antgrid/widgets/terminal_upload_button.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:super_clipboard/super_clipboard.dart' show DataReader;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

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

/// What the pane says to a drop it will not take while the archive is up.
const _dropRefusal = 'Close the scrollback to attach a file';

/// What the shared attach pipeline says to the same drop when it does reach
/// it, which is how a case tells the two refusals apart.
const _pipelineRefusal = '"shot.png" is larger than the 20 MB upload limit';

/// The hover offer the drop target paints once it has accepted a drag.
const _dropOffer = 'Drop to attach';

/// What the touch key row says in place of keys that would reach the covered
/// pane.
const _keysWithdrawn = 'Keys are off while the scrollback is open';

/// What the pane says to a paste whose clipboard read landed after the archive
/// went up.
const _pasteRefusal = 'Close the scrollback to paste';

/// What the pane says when an upload it accepted FINISHES under the archive:
/// the bytes are staged on the machine and the path is not typed.
const _uploadCovered =
    'Upload finished while the scrollback was open — close it and attach again';

/// Every key in the touch strip that writes to the PTY, and the bytes it
/// writes — mirroring `TerminalQuickActionsBar`'s own table.
const _touchKeys = <String, String>{
  'Tab': '\t',
  'Esc': '\x1b',
  'Ctrl+C': '\x03',
  'Ctrl+D': '\x04',
  '↑': '\x1b[A',
  '↓': '\x1b[B',
  '→': '\x1b[C',
  '←': '\x1b[D',
};

/// A drag session carrying one file, the only thing `TerminalDropTarget`
/// inspects. A native drag cannot be synthesized under `flutter_test`, but the
/// region's own callbacks are plain functions on the widget — which is where
/// the accept/refuse decision lives.
class _FakeDropSession extends DropSession {
  @override
  final List<DropItem> items = [_FakeDropItem()];

  @override
  final Listenable onDisposed = Listenable.merge(const <Listenable?>[]);

  @override
  Set<DropOperation> get allowedOperations => const {DropOperation.copy};
}

class _FakeDropItem extends DropItem {
  @override
  bool canProvide(DataFormat f) => f == Formats.fileUri;

  @override
  DataReader? get dataReader => null;

  @override
  Object? get localData => null;

  @override
  List<PlatformFormat> get platformFormats => const [];
}

/// Mirrors terminal_hydration_overlay_test.dart's `_makeService` — a real
/// (local) ProjectSession + TerminalService over a FakeAgentTransport. Only
/// used where a genuine TerminalService is needed at all; most cases here
/// only exercise the widget's own reaction to hydration/tab state.
Future<({TerminalService service, FakeAgentTransport transport})> _makeService(
  void Function(Future<void> Function()) registerTearDown, {
  ProjectSessionMode mode = ProjectSessionMode.local,
}) async {
  final transport = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'p',
    transport: transport,
    mode: mode,
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
  TerminalDisplayMode mode = TerminalDisplayMode.frame,
  TerminalSessionState sessionState = TerminalSessionState.running,
  List<int>? pty,
}) {
  final tab = TerminalTab(
    terminalId: id,
    name: id,
    sessionState: sessionState,
    type: type,
    cols: 80,
    rows: 24,
    mode: mode,
  );
  // [pty] stands in for the running program: everything the engine's transport
  // accepts is a byte the guest on the other end would have read.
  tab.ghostty.attachExternalTransport(
    writeBytes: (b) {
      pty?.addAll(b);
      return true;
    },
  );
  // Never enters TerminalService's own tab map, so nothing else disposes it.
  addTearDown(() async => tab.ghostty.dispose());
  return tab;
}

TerminalState _stateWith({
  Map<String, TerminalHydration> hydration = const {},
}) => TerminalState(hydration: hydration);

/// Tells [tab]'s history model the run has archived rows, the only way the
/// wrapper learns an archive exists — the boundary is restated on every
/// `terminal:frame` and every `terminal:history:page`.
void _archive(TerminalTab tab, {int nextRowId = 400}) =>
    tab.history.applyBoundary(
      TerminalHistoryBoundary(
        epoch: 1,
        firstRowId: 0,
        nextRowId: nextRowId,
        status: 'recording',
      ),
    );

/// The LIVE pane's terminal view. Ordered first in the wrapper's Stack, so
/// this keeps naming it once the reader — which renders through a second
/// engine of its own — is mounted over it.
GhosttyTerminalView _liveView(WidgetTester tester) =>
    tester.widget<GhosttyTerminalView>(find.byType(GhosttyTerminalView).first);

/// The pinned affordance that opens the reader, matched on its tooltip so it
/// cannot be confused with the reader's own toolbar buttons.
final Finder _scrollbackButton = find.byWidgetPredicate(
  (w) => w is AbIconButton && w.tooltip == 'Scrollback',
);

final Finder _backToLiveButton = find.byWidgetPredicate(
  (w) => w is AbIconButton && w.tooltip == 'Back to live',
);

/// Runs out everything a press or a mount books before the wire is read: the
/// grid-freeze settle, the post-frame that carries the settled size back, and
/// `TerminalService.sendResize`'s own debounce, each of which needs a pump of
/// its own to be observed.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// Everything this pane has typed into the PTY through the service — the
/// route the touch keys and the attach pipeline write on, which owes nothing
/// to focus and so is invisible to the reader's key guards.
Iterable<Map<String, dynamic>> _inputs(
  ({TerminalService service, FakeAgentTransport transport}) h,
) => h.transport.sent.where((m) => m['type'] == 'terminal:input');

/// Ctrl+K: an app-level chord with nothing to do with the terminal, so what
/// reaches a `CallbackShortcuts` above the pane measures how much of the
/// focus tree the reader's key guard is stopping.
Future<void> _pressCtrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}

/// Ctrl+V — the paste chord on every platform `flutter_test` defaults to.
Future<void> _pressPasteChord(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// [_settle], then pumps on until the wire stops growing.
///
/// The mount books a resize of its own through two timers and a post-frame,
/// and a fixed pump budget only usually outlasts them: one that does not
/// leaves that resize to land AFTER the gesture under test, which is then
/// blamed for it.
Future<void> _settleWire(
  WidgetTester tester,
  ({TerminalService service, FakeAgentTransport transport}) h,
) async {
  await _settle(tester);
  for (var i = 0; i < 20; i++) {
    final before = h.transport.sent.length;
    await tester.pump(const Duration(milliseconds: 120));
    if (h.transport.sent.length == before) return;
  }
}

/// Every `terminal:resize` this pane has put on the wire.
Iterable<Map<String, dynamic>> _resizes(
  ({TerminalService service, FakeAgentTransport transport}) h,
) => h.transport.sent.where((m) => m['type'] == 'terminal:resize');

/// The wrapper in a fixed box — the shape every scrollback case mounts.
/// [width] is only ever widened, for the cases that press a control far along
/// the quick-actions strip.
Widget _pane(TerminalTab tab, TerminalService service, {double width = 300}) =>
    SizedBox(
      width: width,
      height: 400,
      child: TerminalViewWrapper(tab: tab, terminalService: service),
    );

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
          reason:
              'ended must never dim the screen — it is a real final '
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
                't1': const TerminalHydration(stage: TerminalAttachStage.ended),
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
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
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
          reason:
              'a live selection must show the button before any frame '
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
          reason:
              'Ctrl+C and SendToAgentButton both read the mirror, and '
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

    testWidgets(
      'the wrapper hands the view a selection controller, so a frame can drop '
      'the engine selection and not just the mirror',
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
        expect(
          view.selectionController,
          isNotNull,
          reason:
              'the mirror covers Ctrl+C and SendToAgentButton; the '
              'engine highlight and the view own copy paths resolve from the '
              'anchors themselves, and only this handle reaches those',
        );
      },
    );

    testWidgets(
      'the same anchors are accepted again once the view confirms it cleared',
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

        // What _selectionController.clear() reports back once it has dropped
        // the engine's selection. A view holding nothing can no longer
        // re-offer, so the refusal has done its job and must stand down.
        view.onSelectionContentChanged!(null);
        await tester.pump();

        // The user drags the same region again, deliberately, to copy what
        // the frame actually wrote there. Refusing that would hide the
        // selection they just made.
        view.onSelectionContentChanged!(
          const GhosttyTerminalSelectionContent(
            selection: anchors,
            text: 'what the frame wrote',
          ),
        );
        await tester.pump();

        expect(find.byType(SendToAgentButton), findsOneWidget);
      },
    );

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
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
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
          reason:
              'TerminalService never calls _setState for an applied '
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
    test('sendMouse reports nothing before a frame enables tracking, and a '
        'report after', () {
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
    });

    test('DEC 1004 focus reporting re-asserts against a mode a frame just '
        'turned on', () {
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
    });
  });

  group('the scrollback the live engine no longer holds', () {
    testWidgets('a live frame pane has no native scrollback scrollbar', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final frameTab = _tab(id: 'frame');

      await tester.pumpWidget(
        _wrap(
          _pane(frameTab, h.service),
          terminalState: Stream.value(_stateWith()),
        ),
      );
      await tester.pump();
      expect(
        _liveView(tester).showVerticalScrollbar,
        isFalse,
        reason:
            'the engine holds exactly one screen in frame mode, so the '
            'track can never move and the wheel can never scroll it',
      );
    });

    testWidgets('a scroll clamped at the top opens the reader', (tester) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      expect(find.byType(TerminalHistoryView), findsNothing);

      _liveView(tester).onScrollPastTop!();
      await tester.pump();

      expect(find.byType(TerminalHistoryView), findsOneWidget);
    });

    testWidgets('nothing archived means nothing to open', (tester) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      // `firstRowId == nextRowId` is the boundary's own way of saying the run
      // is recording but has not yet lost a row off the top.
      tab.history.applyBoundary(
        const TerminalHistoryBoundary(
          epoch: 1,
          firstRowId: 12,
          nextRowId: 12,
          status: 'recording',
        ),
      );

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      _liveView(tester).onScrollPastTop!();
      await tester.pump();

      expect(find.byType(TerminalHistoryView), findsNothing);
      expect(_scrollbackButton, findsNothing);
    });

    testWidgets('a user still pushing at the top opens exactly one reader', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      // The callback fires once per clamped scroll step, and a wheel held at
      // the top produces a run of them.
      final open = _liveView(tester).onScrollPastTop!;
      for (var i = 0; i < 6; i++) {
        open();
      }
      await tester.pump();

      expect(find.byType(TerminalHistoryView), findsOneWidget);
    });

    testWidgets('the affordance appears with the run\'s first archived row', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      expect(
        _scrollbackButton,
        findsNothing,
        reason:
            'a control that opens an empty reader is worse than no '
            'control at all',
      );

      // The boundary a later frame carries — the wrapper learns this from the
      // model, which never routes through TerminalService._setState.
      _archive(tab);
      await tester.pump();

      expect(_scrollbackButton, findsOneWidget);
    });

    testWidgets('tapping the affordance opens the reader', (tester) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      await tester.tap(_scrollbackButton);
      await tester.pump();

      expect(find.byType(TerminalHistoryView), findsOneWidget);
      expect(
        _scrollbackButton,
        findsNothing,
        reason:
            'the reader is its own way back, so the control that raised '
            'it has nothing left to offer',
      );
    });

    testWidgets('closing returns the live pane without remounting it', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      final before = tester.element(find.byType(GhosttyTerminalView).first);

      await tester.tap(_scrollbackButton);
      await tester.pump();
      expect(find.byType(TerminalHistoryView), findsOneWidget);

      await tester.tap(_backToLiveButton);
      await tester.pump();

      expect(find.byType(TerminalHistoryView), findsNothing);
      expect(_scrollbackButton, findsOneWidget);
      expect(
        identical(
          tester.element(find.byType(GhosttyTerminalView).first),
          before,
        ),
        isTrue,
        reason:
            'the reader is mounted OVER the live pane, so the engine, its '
            'focus and its grid bookkeeping survive the round trip',
      );
    });

    testWidgets('a respawn closes the reader rather than leaving it stale', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      await tester.tap(_scrollbackButton);
      await tester.pump();
      expect(find.byType(TerminalHistoryView), findsOneWidget);

      // What TerminalService._resetFrameTracking does when the PTY respawns
      // or the connection is re-established: a fresh run archives into a
      // boundary this model has never seen, so everything loaded names rows
      // the agent will not serve again.
      tab.history.reset();
      await tester.pump();

      expect(
        find.byType(TerminalHistoryView),
        findsNothing,
        reason:
            'the reader\'s engine holds the last page it ingested and '
            'nothing refills it — left up, it would go on showing a run that '
            'is over',
      );
      expect(_scrollbackButton, findsNothing);
    });
  });

  group('D1: the reader must never let a key reach the live program', () {
    testWidgets(
      'a key press with the pane behind still focused writes nothing to the pty',
      (tester) async {
        if (_skipWithoutNative()) return;
        final pty = <int>[];
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1', pty: pty);
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();

        // The control: this key does reach the guest from a pane the user can
        // see, so the assertion below cannot pass merely because nothing in
        // this harness types at all.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(pty, isNotEmpty);

        await tester.tap(_scrollbackButton);
        await tester.pump();
        await tester.pump();

        // The window the backstop exists for: the reader is up, but the live
        // pane holds the keyboard. A rebuild that re-asserted autofocus, a
        // reader that could not take focus, or simply the frame before the
        // hand-off lands all look exactly like this.
        final live = _liveView(tester).focusNode!;
        live.requestFocus();
        await tester.pump();
        expect(live.hasFocus, isTrue);

        pty.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(
          pty,
          isEmpty,
          reason:
              'the reader covers the pane edge to edge, so a forwarded '
              'key is typed into a program the user cannot see',
        );
        expect(
          find.byType(TerminalHistoryView),
          findsNothing,
          reason:
              'swallowing the key must not also swallow the only way out '
              'of the reader',
        );
      },
    );

    testWidgets(
      'Escape dismisses the reader instead of interrupting the agent',
      (tester) async {
        if (_skipWithoutNative()) return;
        final pty = <int>[];
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1', type: 'agent', pty: pty);
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
            agentTab: tab,
          ),
        );
        await tester.pump();
        await tester.tap(_scrollbackButton);
        await tester.pump();
        await tester.pump();

        pty.clear();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump();

        expect(
          pty,
          isEmpty,
          reason:
              'Escape in an agent pane is cancel-the-current-turn, and the '
              'pane that would show it interrupted is covered',
        );
        expect(find.byType(TerminalHistoryView), findsNothing);
      },
    );

    testWidgets(
      'raising the reader takes the keyboard off the live pane and closing '
      'gives it straight back',
      (tester) async {
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1');
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();
        final live = _liveView(tester).focusNode!;
        expect(live.hasFocus, isTrue);

        await tester.tap(_scrollbackButton);
        await tester.pump();
        await tester.pump();

        final readerScope = FocusScope.of(
          tester.element(find.byType(TerminalHistoryView)),
        );
        expect(
          identical(
            readerScope,
            FocusScope.of(
              tester.element(find.byType(GhosttyTerminalView).first),
            ),
          ),
          isFalse,
          reason:
              'without a scope of its own, "is the keyboard inside the '
              'reader" is not a question this pane can answer — and that '
              'question is what decides whether a key may be forwarded',
        );
        expect(
          readerScope.hasFocus,
          isTrue,
          reason: 'while the archive is on screen the keyboard belongs to it',
        );
        expect(live.hasFocus, isFalse);

        await tester.tap(_backToLiveButton);
        await tester.pump();
        await tester.pump();
        expect(
          live.hasFocus,
          isTrue,
          reason:
              'a user who dismissed the reader is back at the prompt and '
              'must not have to click before typing',
        );
      },
    );

    testWidgets(
      'a key swallowed with the pane behind focused hands the keyboard back',
      (tester) async {
        if (_skipWithoutNative()) return;
        final pty = <int>[];
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1', pty: pty);
        _archive(tab);

        var fired = 0;
        await tester.pumpWidget(
          _wrap(
            CallbackShortcuts(
              bindings: {
                const SingleActivator(
                  LogicalKeyboardKey.keyK,
                  control: true,
                ): () =>
                    fired++,
              },
              child: _pane(tab, h.service),
            ),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();

        await tester.tap(_scrollbackButton);
        await tester.pump();
        await tester.pump();

        final live = _liveView(tester).focusNode!;
        live.requestFocus();
        await tester.pump();
        expect(live.hasFocus, isTrue);

        pty.clear();
        await _pressCtrlK(tester);
        await tester.pump();

        expect(
          pty,
          isEmpty,
          reason:
              'stopping the focus tree is the only thing that keeps a key '
              'out of a program the user cannot see',
        );
        expect(
          live.hasFocus,
          isFalse,
          reason:
              'but the swallow may not be the resting state: it stops the '
              'WHOLE tree, so the keyboard has to go back to the archive',
        );

        await _pressCtrlK(tester);
        await tester.pump();

        expect(
          fired,
          greaterThan(0),
          reason:
              'an app-level shortcut is not the terminal, and reading '
              'history must not cost the user every binding in the app',
        );
        expect(pty, isEmpty);
      },
    );

    testWidgets(
      'a reader closed while another pane holds the keyboard does not take '
      'it back',
      (tester) async {
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1');
        _archive(tab);
        final elsewhere = FocusNode(debugLabel: 'anotherPane');
        addTearDown(elsewhere.dispose);

        await tester.pumpWidget(
          _wrap(
            Column(
              children: [
                _pane(tab, h.service),
                Focus(
                  focusNode: elsewhere,
                  child: const SizedBox(width: 20, height: 20),
                ),
              ],
            ),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();
        await tester.tap(_scrollbackButton);
        await tester.pump();
        await tester.pump();

        elsewhere.requestFocus();
        await tester.pump();
        expect(elsewhere.hasFocus, isTrue);

        // A close the user did not ask for: the run respawned under them while
        // they were typing somewhere else entirely.
        tab.history.reset();
        await tester.pump();
        await tester.pump();

        expect(find.byType(TerminalHistoryView), findsNothing);
        expect(
          elsewhere.hasFocus,
          isTrue,
          reason:
              'handing the keyboard to the live pane on a close nobody '
              'asked for would eat the keystrokes of whatever the user is '
              'actually typing in',
        );
        expect(_liveView(tester).focusNode!.hasFocus, isFalse);
      },
    );
  });

  group('the reader is a lid on the live pane, not a layer over it', () {
    testWidgets(
      'the touch quick-action keys are withdrawn, not left live beneath it',
      (tester) async {
        // The bar exists only where there is no physical keyboard, which is no
        // host `flutter test` runs on.
        debugHasPhysicalKeyboardOverride = false;
        addTearDown(() => debugHasPhysicalKeyboardOverride = null);

        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1');
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            // Wide enough for the WHOLE strip: the bar scrolls horizontally,
            // and a key parked off-screen is one the loop below cannot press.
            _pane(tab, h.service, width: 1000),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();

        // Every key that writes to the PTY, not one of them: the withdrawal
        // is a cover over a strip, so a key the cover happens to miss would
        // still be live.
        Future<void> tapEveryKey() async {
          for (final label in _touchKeys.keys) {
            await tester.tap(find.text(label), warnIfMissed: false);
            await tester.pump();
          }
        }

        // The control: these keys do reach the PTY from a pane the user can
        // see, so the assertion below cannot pass because the harness never
        // delivered a press at all.
        await tapEveryKey();
        expect(_inputs(h).map((m) => m['data']), _touchKeys.values);
        h.transport.sent.clear();

        await tester.tap(_scrollbackButton);
        await tester.pump();

        await tapEveryKey();
        expect(
          _inputs(h),
          isEmpty,
          reason:
              'the bar sits OUTSIDE the Stack the reader covers and writes '
              'to the PTY through a plain callback — left live, a phone user '
              'reading history taps a visible Esc and cancels the turn',
        );
        expect(
          find.byType(TerminalQuickActionsBar),
          findsOneWidget,
          reason:
              'and it may not be unmounted to achieve that: it is a row of '
              'the pane Column, so taking it out resizes the agent PTY (see '
              'the wire case in "the reader is not the terminal")',
        );
        expect(
          find.text(_keysWithdrawn),
          findsOneWidget,
          reason: 'a key that no longer answers has to say so where it was',
        );

        await tester.tap(_backToLiveButton);
        await tester.pump();
        expect(find.text(_keysWithdrawn), findsNothing);
        await tapEveryKey();
        expect(
          _inputs(h).map((m) => m['data']),
          _touchKeys.values,
          reason: 'the keys come back with the live pane',
        );
      },
    );

    testWidgets('a drag over the archive is refused before it is offered', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      final session = _FakeDropSession();
      DropRegion region() => tester.widget<DropRegion>(find.byType(DropRegion));
      Future<DropOperation> dragOver() async => await region().onDropOver(
        DropOverEvent(
          session: session,
          position: DropPosition(local: Offset.zero, global: Offset.zero),
        ),
      );
      // What the platform does once a region has answered with an operation,
      // so the painted offer is observable at all.
      Future<void> enter() async {
        region().onDropEnter?.call(DropEvent(session: session));
        await tester.pump();
      }

      // The control: over the live pane the drag is both accepted and offered,
      // so the assertions below cannot pass because this harness never drove
      // the region at all.
      expect(await dragOver(), DropOperation.copy);
      await enter();
      expect(find.text(_dropOffer), findsOneWidget);

      // The reader goes up MID-DRAG, with the offer already painted — the only
      // order that reaches a refusal with the hover state already true. A drag
      // that STARTS under the reader is answered `none`, and `onDropEnter`
      // fires only for a region that answered otherwise (super_drag_and_drop
      // 0.9.1, `drop_internal.dart`, `_DropSession.update`), so that one never
      // paints an offer at all.
      await tester.tap(_scrollbackButton);
      await tester.pump();

      expect(
        find.text(_dropOffer),
        findsNothing,
        reason:
            'the hover overlay is the last child of the drop target own '
            'Stack — above the reader — so an offer left standing paints '
            '"Drop to attach" over the archive and is then refused',
      );
      expect(
        await dragOver(),
        DropOperation.none,
        reason:
            'the pane refuses a drop under the reader, so answering copy '
            'is an offer it will not take',
      );
    });

    testWidgets(
      'a clipboard read outliving the live pane cannot stage into the archive',
      (tester) async {
        final h = await _makeService(
          addTearDown,
          mode: ProjectSessionMode.relay,
        );
        final tab = _tab(id: 't1');
        _archive(tab);
        // Held open across the gesture: the paste chord reads the clipboard
        // asynchronously, and `_historyOpen` is only checked when the key
        // arrives.
        final clipboard = Completer<ClipboardImage?>();

        await tester.pumpWidget(
          _wrap(
            SizedBox(
              width: 300,
              height: 400,
              child: TerminalViewWrapper(
                tab: tab,
                terminalService: h.service,
                readImage: () => clipboard.future,
              ),
            ),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();
        _liveView(tester).focusNode!.requestFocus();
        await tester.pump();

        await _pressPasteChord(tester);

        await tester.tap(_scrollbackButton);
        await tester.pump();

        clipboard.complete(
          ClipboardImage(
            fileName: 'shot.png',
            mimeType: 'image/png',
            // Over the cap for the same reason the drop case is: the pipeline
            // answers a file this size from memory, so the refusal below names
            // which of the two refused it.
            bytes: Uint8List(UploadService.kMaxUploadBytes + 1),
          ),
        );
        await tester.pump();
        await tester.pump();

        expect(
          find.text(_dropRefusal),
          findsOneWidget,
          reason:
              'the reader went up inside the clipboard read, so the '
              'continuation has to re-ask rather than trust the check the key '
              'made',
        );
        expect(
          find.text(_pipelineRefusal),
          findsNothing,
          reason:
              'reaching the pipeline means the continuation ran into the '
              'covered pane; with a file it could stage, it would have typed '
              'the path into a prompt the archive is covering',
        );
      },
    );

    testWidgets('a file dropped on the archive is refused, not staged', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      // Over the upload cap on purpose: the shared pipeline answers a drop
      // that size from memory, so the control below can reach it without an
      // upload this harness has no agent to finish.
      final oversized = Uint8List(UploadService.kMaxUploadBytes + 1);
      Future<void> drop() => tester
          .widget<TerminalDropTarget>(find.byType(TerminalDropTarget))
          .attach(bytes: oversized, fileName: 'shot.png');

      // The control: dropped on the live pane the file reaches the shared
      // attach pipeline, which refuses it in its own words — so the seam this
      // case drives is the real one, and the assertion below cannot pass
      // because nothing was ever wired to it.
      await drop();
      await tester.pump();
      expect(find.text(_pipelineRefusal), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold)),
      ).clearSnackBars();
      await tester.pump();

      await tester.tap(_scrollbackButton);
      await tester.pump();
      await drop();
      await tester.pump();

      expect(
        find.text(_dropRefusal),
        findsOneWidget,
        reason:
            'the callback a drop is routed into is gated on its own: the '
            'case above pins the region refusing the OPERATION, this one pins '
            'what a call that reached the callback anyway meets',
      );
      expect(
        find.text(_pipelineRefusal),
        findsNothing,
        reason: 'the refusal is ahead of the pipeline, not inside it',
      );
      // `_inputs` is deliberately NOT asserted here. The path a drop types is
      // emitted by the uploader after an upload this harness has no agent to
      // finish, so the wire stays empty with the gate and without it. The pair
      // above is what pins that harm instead: a drop reaches the PTY only
      // through the uploader's own insert, so a refusal proven to be ahead of
      // the pipeline is a refusal ahead of the typing.
    });

    testWidgets(
      'a file picked before the reader went up is refused, not staged',
      (tester) async {
        debugHasPhysicalKeyboardOverride = true;
        addTearDown(() => debugHasPhysicalKeyboardOverride = null);
        final h = await _makeService(
          addTearDown,
          mode: ProjectSessionMode.relay,
        );
        final tab = _tab(id: 't1');
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();

        // Held across the gesture the way the platform picker holds it: the
        // control is withdrawn while the OS dialog is up, and its continuation
        // runs into whatever the pane has become.
        final onPicked = tester
            .widget<TerminalAttachOverlayButton>(
              find.byType(TerminalAttachOverlayButton),
            )
            .onPicked;
        final picked = PickedUpload(
          name: 'shot.png',
          bytes: Uint8List(UploadService.kMaxUploadBytes + 1),
        );

        // The control: from the live pane that same continuation reaches the
        // shared pipeline, so the assertions below cannot pass because nothing
        // was ever wired to it.
        await onPicked(picked);
        await tester.pump();
        expect(find.text(_pipelineRefusal), findsOneWidget);
        ScaffoldMessenger.of(
          tester.element(find.byType(Scaffold)),
        ).clearSnackBars();
        await tester.pump();

        await tester.tap(_scrollbackButton);
        await tester.pump();
        await onPicked(picked);
        await tester.pump();

        expect(
          find.text(_dropRefusal),
          findsOneWidget,
          reason:
              'the picker outlives the button, so the continuation has to '
              'ask the pane again rather than trust the state that built it',
        );
        expect(find.text(_pipelineRefusal), findsNothing);
      },
    );

    testWidgets(
      'a file picked from the touch strip before the reader went up is '
      'refused, not staged',
      (tester) async {
        // The strip is built only where there is no physical keyboard, and the
        // desktop attach button only where there is one — so neither case can
        // stand in for the other, and the picker each owns needs its own.
        debugHasPhysicalKeyboardOverride = false;
        addTearDown(() => debugHasPhysicalKeyboardOverride = null);
        final h = await _makeService(
          addTearDown,
          mode: ProjectSessionMode.relay,
        );
        final tab = _tab(id: 't1');
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();

        // Held across the gesture the way the platform picker holds it: the
        // strip is withdrawn while the OS dialog is up, and its continuation
        // runs into whatever the pane has become.
        final onPicked = tester
            .widget<TerminalQuickActionsBar>(
              find.byType(TerminalQuickActionsBar),
            )
            .onPicked;
        final picked = PickedUpload(
          name: 'shot.png',
          bytes: Uint8List(UploadService.kMaxUploadBytes + 1),
        );

        // The control: from the live pane that same continuation reaches the
        // shared pipeline, so the assertions below cannot pass because nothing
        // was ever wired to it.
        await onPicked(picked);
        await tester.pump();
        expect(find.text(_pipelineRefusal), findsOneWidget);
        ScaffoldMessenger.of(
          tester.element(find.byType(Scaffold)),
        ).clearSnackBars();
        await tester.pump();

        await tester.tap(_scrollbackButton);
        await tester.pump();
        await onPicked(picked);
        await tester.pump();

        expect(
          find.text(_dropRefusal),
          findsOneWidget,
          reason:
              'the picker outlives the strip, so the continuation has to '
              'ask the pane again rather than trust the state that built it',
        );
        expect(find.text(_pipelineRefusal), findsNothing);
      },
    );

    testWidgets('an upload that finishes under the reader types nothing', (
      tester,
    ) async {
      // A physical keyboard and a LOCAL session, so neither the touch strip
      // nor the desktop attach button is built and the overlay column holds
      // only the progress strip and the scrollback control this drives.
      debugHasPhysicalKeyboardOverride = true;
      addTearDown(() => debugHasPhysicalKeyboardOverride = null);
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      // The REAL UploadService, driven through the bridge's own protocol and
      // under the cap, so the path genuinely comes back — the multi-second
      // wait every attach gesture's reader check is made before.
      Future<void> upload({required bool openReaderMidUpload}) async {
        unawaited(
          tester
              .widget<TerminalDropTarget>(find.byType(TerminalDropTarget))
              .attach(
                bytes: Uint8List.fromList(const [1, 2, 3]),
                fileName: 'shot.png',
              ),
        );
        await tester.pump();
        final requestId =
            h.transport.sent.lastWhere(
                  (m) => m['type'] == 'file:upload-start',
                )['requestId']
                as String;
        if (openReaderMidUpload) {
          await tester.tap(_scrollbackButton);
          await tester.pump();
        }
        h.transport.emit('file:upload-ready', {
          'requestId': requestId,
          'uploadId': 'u1',
        });
        await tester.pump();
        h.transport.emit('file:upload-ack', {'uploadId': 'u1', 'seq': 0});
        await tester.pump();
        h.transport.emit('file:upload-result', {
          'requestId': requestId,
          'uploadId': 'u1',
          'ok': true,
          'path': '/staged/shot.png',
        });
        await tester.pump();
        await tester.pump();
      }

      // The control: finished over the live pane, the path IS typed — so the
      // assertion below cannot pass because this harness never carried an
      // upload to completion.
      await upload(openReaderMidUpload: false);
      expect(_inputs(h).map((m) => m['data']), ['"/staged/shot.png" ']);
      h.transport.sent.clear();

      await upload(openReaderMidUpload: true);
      expect(
        _inputs(h),
        isEmpty,
        reason:
            'the gesture that started this upload checked the reader '
            'before the round trip, and the reader went up inside it — the '
            'path would be typed into a prompt the archive is covering',
      );
      expect(
        find.text(_uploadCovered),
        findsOneWidget,
        reason:
            'the bytes reached the machine and nothing reached the '
            'prompt, so a silent refusal reads as a finished attach',
      );

      // Refused, not held: the path is gone, not queued behind the reader.
      await tester.tap(_backToLiveButton);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(_inputs(h), isEmpty);
    });

    testWidgets(
      'a clipboard text read outliving the live pane is not typed into it',
      (tester) async {
        final h = await _makeService(addTearDown);
        final pty = <int>[];
        final tab = _tab(id: 't1', pty: pty);
        _archive(tab);

        // The platform's clipboard reply, held until the archive is up: the
        // chord checks the pane once, when the key arrives.
        final clipboard = Completer<Map<String, Object?>>();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => call.method == 'Clipboard.getData'
              ? await clipboard.future
              : null,
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();
        _liveView(tester).focusNode!.requestFocus();
        await tester.pump();
        await _pressPasteChord(tester);

        await tester.tap(_scrollbackButton);
        await tester.pump();
        clipboard.complete(<String, Object?>{'text': 'rm -rf /'});
        await tester.pump();
        await tester.pump();

        expect(
          pty,
          isEmpty,
          reason:
              'the reader went up inside the clipboard read, and this '
              'branch writes the payload straight to the guest',
        );
        expect(find.text(_pasteRefusal), findsOneWidget);

        // The control: the same chord on the live pane does reach the guest,
        // so the assertion above cannot pass because this harness never
        // delivered a paste at all.
        await tester.tap(_backToLiveButton);
        await tester.pump();
        _liveView(tester).focusNode!.requestFocus();
        await tester.pump();
        await _pressPasteChord(tester);
        await tester.pump();
        expect(utf8.decode(pty), 'rm -rf /');
      },
    );

    testWidgets('the attach control is withdrawn under the reader', (
      tester,
    ) async {
      // Desktop's only attach route, and only on a relay session: a local
      // agent reads the user's own disk.
      debugHasPhysicalKeyboardOverride = true;
      addTearDown(() => debugHasPhysicalKeyboardOverride = null);
      final h = await _makeService(addTearDown, mode: ProjectSessionMode.relay);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      expect(find.byType(TerminalAttachOverlayButton), findsOneWidget);

      await tester.tap(_scrollbackButton);
      await tester.pump();

      expect(
        find.byType(TerminalAttachOverlayButton),
        findsNothing,
        reason:
            'the same rule the send-to-agent offer is held to: built under '
            'a full-bleed reader it is painted underneath and untappable',
      );

      await tester.tap(_backToLiveButton);
      await tester.pump();
      expect(find.byType(TerminalAttachOverlayButton), findsOneWidget);
    });
  });

  group('D2: an archive epoch turnover empties the reader under the user', () {
    testWidgets('a new epoch closes the reader rather than blanking it', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      await tester.tap(_scrollbackButton);
      await tester.pump();
      expect(find.byType(TerminalHistoryView), findsOneWidget);

      // The guest cleared its scrollback (CSI 3 J / RIS) and the next frame
      // carries the new epoch. `TerminalHistoryModel.applyBoundary` discards
      // every loaded row, but the fresh epoch is already archiving — so
      // `hasHistory` never goes false and nothing else can see the break.
      tab.history.applyBoundary(
        const TerminalHistoryBoundary(
          epoch: 2,
          firstRowId: 0,
          nextRowId: 40,
          status: 'recording',
        ),
      );
      await tester.pump();

      expect(
        find.byType(TerminalHistoryView),
        findsNothing,
        reason:
            'the reader loads a first page on mount and nowhere else, so '
            'one left standing over a discarded epoch says "Nothing has '
            'scrolled off yet" about a run whose boundary says otherwise',
      );
      expect(
        _scrollbackButton,
        findsOneWidget,
        reason:
            'the new epoch has archived rows of its own, so the way back '
            'in stays — and re-entering is what loads them',
      );
    });
  });

  group('D3: the affordance is the archive route an agent pane has', () {
    testWidgets(
      'a mouse-reporting guest swallows the wheel, and the control still '
      'reaches the archive',
      (tester) async {
        if (_skipWithoutNative()) return;
        final pty = <int>[];
        final h = await _makeService(addTearDown);
        final tab = _tab(id: 't1', pty: pty);
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();

        // What every agent TUI does on its first frame. From here the view's
        // own wheel handling forwards each notch to the guest as button 4/5
        // and returns before anything can clamp at the top.
        tab.ghostty.appendOutputBytes('\x1b[?1000h'.codeUnits);
        await tester.pump();

        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        final at = tester.getCenter(find.byType(GhosttyTerminalView).first);
        await tester.sendEventToBinding(pointer.hover(at));
        pty.clear();
        for (var i = 0; i < 6; i++) {
          await tester.sendEventToBinding(pointer.scroll(const Offset(0, -60)));
        }
        await tester.pump();

        expect(
          pty,
          isNotEmpty,
          reason:
              'the notches reached the view and it gave them to the guest '
              '— without that this proves nothing about the clamp',
        );
        expect(
          find.byType(TerminalHistoryView),
          findsNothing,
          reason:
              'onScrollPastTop cannot fire while the guest owns the '
              'wheel, which is every pane this feature exists for',
        );

        await tester.tap(_scrollbackButton);
        await tester.pump();
        expect(find.byType(TerminalHistoryView), findsOneWidget);
      },
    );

    testWidgets('a live selection does not withdraw the control', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1', type: 'agent');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(
          _pane(tab, h.service),
          terminalState: Stream.value(_stateWith()),
          agentTab: tab,
        ),
      );
      await tester.pump();

      _liveView(tester).onSelectionContentChanged!(
        const GhosttyTerminalSelectionContent(
          selection: GhosttyTerminalSelection(
            base: GhosttyTerminalCellPosition(row: 0, col: 0),
            extent: GhosttyTerminalCellPosition(row: 0, col: 4),
          ),
          text: 'hello',
        ),
      );
      await tester.pump();
      expect(find.byType(SendToAgentButton), findsOneWidget);

      expect(
        _scrollbackButton,
        findsOneWidget,
        reason:
            'suppressing it here leaves a Claude Code pane with a live '
            'selection no route to the archive at all',
      );
      await tester.tap(_scrollbackButton);
      await tester.pump();
      expect(find.byType(TerminalHistoryView), findsOneWidget);
    });

    testWidgets('the send-to-agent offer is withdrawn under the reader', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1', type: 'agent');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(
          _pane(tab, h.service),
          terminalState: Stream.value(_stateWith()),
          agentTab: tab,
        ),
      );
      await tester.pump();
      _liveView(tester).onSelectionContentChanged!(
        const GhosttyTerminalSelectionContent(
          selection: GhosttyTerminalSelection(
            base: GhosttyTerminalCellPosition(row: 0, col: 0),
            extent: GhosttyTerminalCellPosition(row: 0, col: 4),
          ),
          text: 'hello',
        ),
      );
      await tester.pump();

      await tester.tap(_scrollbackButton);
      await tester.pump();
      expect(
        find.byType(SendToAgentButton),
        findsNothing,
        reason:
            'it positions itself into the same Stack, so under a '
            'full-bleed reader it is painted underneath and untappable',
      );

      await tester.tap(_backToLiveButton);
      await tester.pump();
      expect(
        find.byType(SendToAgentButton),
        findsOneWidget,
        reason: 'the engine kept the selection, so the offer is real again',
      );
    });
  });

  group('the reader is not the terminal', () {
    testWidgets('a press inside the archive books no width claim', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      h.service.setClientId(_myClientId);
      final tab = _tab(id: 't1');
      _archive(tab);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      await _settleWire(tester, h);
      h.transport.sent.clear();

      // The control, so the assertion below cannot pass because the claim
      // never reached the wire in this harness at all: a press on the live
      // grid is exactly what booking a claim is for.
      await tester.tapAt(tester.getCenter(find.byType(GhosttyTerminalView)));
      await _settleWire(tester, h);
      expect(_resizes(h), hasLength(1));

      await tester.tap(_scrollbackButton);
      await _settleWire(tester, h);
      h.transport.sent.clear();

      await tester.tapAt(tester.getCenter(find.byType(TerminalHistoryView)));
      await _settle(tester);

      expect(
        _resizes(h),
        isEmpty,
        reason:
            'the claim Listener is translucent, so a scroll or a '
            'selection drag in the archive would otherwise take terminal '
            'width ownership from whichever device is driving',
      );
    });

    testWidgets(
      'opening and closing the reader on a touch pane resizes no PTY',
      (tester) async {
        // The pane that HAS a quick-actions row — the row the reader would
        // otherwise take out of the Column.
        debugHasPhysicalKeyboardOverride = false;
        addTearDown(() => debugHasPhysicalKeyboardOverride = null);

        final h = await _makeService(addTearDown);
        h.service.setClientId(_myClientId);
        final tab = _tab(id: 't1');
        _archive(tab);

        await tester.pumpWidget(
          _wrap(
            _pane(tab, h.service, width: 700),
            terminalState: Stream.value(_stateWith()),
          ),
        );
        await tester.pump();
        await _settleWire(tester, h);

        // The control: this pane is the driver and does put its measured grid
        // on the wire, so the assertions below cannot pass because nothing in
        // this harness ever sends a resize.
        expect(_resizes(h), isNotEmpty);
        h.transport.sent.clear();

        await tester.tap(_scrollbackButton);
        await _settleWire(tester, h);
        expect(
          _resizes(h),
          isEmpty,
          reason:
              'the quick-actions bar is a ROW of the pane Column: '
              'withdrawing it by unmounting grows the live terminal, and the '
              'driver answers a changed grid by re-laying-out the agent own '
              'screen — for the act of reading its scrollback',
        );

        await tester.tap(_backToLiveButton);
        await _settleWire(tester, h);
        expect(
          _resizes(h),
          isEmpty,
          reason: 'and the close puts the row back, which is the second one',
        );
      },
    );
  });

  group('a stopped terminal', () {
    testWidgets('retains the final grid and offers Start after consumption', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1', sessionState: TerminalSessionState.exited);
      tab.replaceEpoch.value = 1;
      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();
      expect(find.byType(GhosttyTerminalView), findsOneWidget);
      expect(find.byType(AbEmptyState), findsNothing);
      expect(find.text('Start'), findsOneWidget);
    });
    testWidgets('offers Start in place of the grid, and asks for it', (
      tester,
    ) async {
      final h = await _makeService(addTearDown);
      final tab = _tab(id: 't1', sessionState: TerminalSessionState.exited);

      await tester.pumpWidget(
        _wrap(_pane(tab, h.service), terminalState: Stream.value(_stateWith())),
      );
      await tester.pump();

      expect(find.byType(AbEmptyState), findsOneWidget);
      expect(find.text('Terminal stopped'), findsOneWidget);
      expect(
        find.byType(GhosttyTerminalView),
        findsNothing,
        reason: 'there is no screen to paint and no grid to size',
      );

      await tester.tap(find.byType(AbButton));
      await tester.pump();

      expect(
        h.transport.sent.where((m) => m['type'] == 'terminal:start'),
        hasLength(1),
      );
    });
  });
}
