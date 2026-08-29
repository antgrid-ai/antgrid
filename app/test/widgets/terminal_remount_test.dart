// A viewer's grid must be authoritative from its very first frame.
//
// `terminal_screen.dart` keys the wrapper by terminalId, so switching sessions
// and coming back REMOUNTS it. While the wrapper waited for the view's
// post-frame `onCellMetricsChanged` report, frame 1 of every remount fell into
// the driver branch and sized the engine to the LOCAL viewport, and frame 2
// corrected it to the driver's authoritative width — two engine resizes where
// the authoritative width never moved, plus a runtimeType swap at the same tree
// position that disposed the whole `GhosttyTerminalView` state. Neither is
// cosmetic: `ghostty_vte_flutter` does not reflow, so an Ink-style TUI leaks
// stale fragments across a grid change, which is what "returning to a terminal
// shows blank regions" looked like from the user's side.
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/terminal_cell_metrics.dart';
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

/// The view's default horizontal padding, pinned against the package by
/// `terminal_cell_metrics_contract_test.dart`.
const double _hPad = AbTokens.space8 * 2;

Future<TerminalService> _makeService(
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
  return service;
}

/// A viewer tab, with its engine registered for teardown.
///
/// `TerminalTab`'s constructor builds a `GhosttyTerminalController` eagerly, and
/// these tabs never enter `TerminalService._state.tabs` — so the service's own
/// dispose never reaches them and each one is a leaked native VT for the life of
/// the test process.
TerminalTab _tab({
  required String id,
  required int cols,
  required void Function(Future<void> Function()) registerTearDown,
}) {
  final tab = TerminalTab(
    terminalId: id,
    name: id,
    sessionState: TerminalSessionState.running,
    type: 'service',
    cols: cols,
    rows: 24,
    // Driven by another device → this view is a pure viewer, the
    // desktop-plus-phone case the product is built around.
    driverClientId: _otherClientId,
  );
  tab.ghostty.attachExternalTransport(writeBytes: (_) => true);
  registerTearDown(() async => tab.ghostty.dispose());
  return tab;
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [
    clientIdProvider.overrideWith((ref) async => _myClientId),
    agentTerminalProvider.overrideWith((ref) => null),
    appSettingsServiceProvider.overrideWith(
      () => AppSettingsService(
        _settingsPrefs,
        AppSettings.fromPrefs(_settingsPrefs),
      ),
    ),
  ],
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    home: Scaffold(body: child),
  ),
);

/// A scroll view the WRAPPER put above the terminal.
///
/// `GhosttyTerminalView` owns one of its own for its scrollback, so the
/// contract can only be stated as an ancestor: the non-driver path scales its
/// grid down rather than scrolling it, on BOTH axes, because a scroll view
/// wrapped around the terminal loses every drag to that inner scrollable and
/// strands the rows it exists to reveal.
Finder get _wrappingScrollView => find.ancestor(
  of: find.byType(GhosttyTerminalView),
  matching: find.byType(SingleChildScrollView),
);

/// The wrapper branches on the target platform to pick the
/// claim/letterbox/scale paths these tests assert on, so every case here
/// needs the override.
///
/// It has to arrive as a VARIANT and not as a `setUp`/`tearDown` pair:
/// `_verifyInvariants` runs at the end of the test BODY and fails any test that
/// leaves a foundation debug variable set, which is before a `tearDown` could
/// clear it. The variant's own restore runs in the body's `finally`, so it also
/// survives an `expect` that throws — which a body clearing the global on its
/// last line does not.
final _macOnly = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    useInMemoryPrefs();
    _settingsPrefs = await openAppSettingsPrefs();
  });

  testWidgets('a non-driver remount performs zero engine resizes', (
    tester,
  ) async {
    final service = await _makeService(addTearDown);
    final tab = _tab(id: 'remount', cols: 200, registerTearDown: addTearDown);

    Widget at(String key) => _wrap(
      Center(
        child: SizedBox(
          width: 300,
          height: 400,
          child: TerminalViewWrapper(
            key: ValueKey(key),
            tab: tab,
            terminalService: service,
          ),
        ),
      ),
    );

    await tester.pumpWidget(at('first'));
    await tester.pumpAndSettle();

    // Production passes `onResize: null`, so the hook is free to borrow here.
    // `controller.resize` returns before notifying when cols, rows AND both
    // cell pixel metrics are unchanged, so every call counted below is a real
    // grid change under the guest.
    var resizes = 0;
    tab.ghostty.attachExternalTransport(
      writeBytes: (_) => true,
      onResize: (_, _, _, _) => resizes++,
    );

    await tester.pumpWidget(at('second'));
    await tester.pumpAndSettle();

    expect(
      resizes,
      0,
      reason:
          'the authoritative width did not move, so returning to this terminal '
          'must not touch the engine grid at all',
    );
  }, variant: _macOnly);

  testWidgets('the first frame of a non-driver mount is already authoritative', (
    tester,
  ) async {
    final service = await _makeService(addTearDown);
    final tab = _tab(
      id: 'first-frame',
      cols: 200,
      registerTearDown: addTearDown,
    );

    // No settle: `pumpWidget` renders exactly one frame, and the view's metrics
    // report cannot have been acted on yet. 200 cols overflows the 300px
    // viewport, so an authoritative first frame is laid out WIDER than the
    // viewport (and then scaled to fit), where a viewport-derived one is the
    // driver freeze and matches the viewport exactly.
    await tester.pumpWidget(
      _wrap(
        Center(
          child: SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: service),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(GhosttyTerminalView)).width,
      greaterThan(300),
    );
    expect(find.byType(FittedBox), findsOneWidget);
    expect(_wrappingScrollView, findsNothing);

    await tester.pumpAndSettle();
  }, variant: _macOnly);

  testWidgets(
    'crossing the fits/scaled boundary reparents rather than remounts',
    (tester) async {
      final service = await _makeService(addTearDown);
      final tab = _tab(id: 'boundary', cols: 40, registerTearDown: addTearDown);

      Widget atWidth(double width) => _wrap(
        Center(
          child: SizedBox(
            width: width,
            // Tall enough to clear 24 rows, so WIDTH alone decides whether
            // this grid is painted at natural size or scaled down.
            height: 560,
            child: TerminalViewWrapper(tab: tab, terminalService: service),
          ),
        ),
      );

      // Wide enough for 40 cols: painted at its natural size, merely centred.
      await tester.pumpWidget(atWidth(700));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(GhosttyTerminalView)).width,
        closeTo(tester.getSize(find.byType(GhosttyTerminalView)).width, 0.5),
      );
      final before = tester.element(find.byType(GhosttyTerminalView));

      // Narrower than the authoritative width, so the same grid is now scaled
      // down to fit. A pure layout event: the engine geometry is unchanged, so
      // disposing the view's selection, focus node, scroll offset and
      // soft-keyboard hooks for it is pure loss.
      await tester.pumpWidget(atWidth(200));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(GhosttyTerminalView)).width,
        lessThan(tester.getSize(find.byType(GhosttyTerminalView)).width),
      );
      expect(_wrappingScrollView, findsNothing);

      expect(
        identical(tester.element(find.byType(GhosttyTerminalView)), before),
        isTrue,
        reason: 'the view must be reparented across the swap, not rebuilt',
      );
    },
    variant: _macOnly,
  );

  testWidgets('a zoom step is correct on its first frame', (tester) async {
    final service = await _makeService(addTearDown);
    final tab = _tab(id: 'zoom', cols: 5, registerTearDown: addTearDown);

    await tester.pumpWidget(
      _wrap(
        Center(
          child: SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: service),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    double widthFor(double fontSize) {
      final cell = measureTerminalCell(
        fontFamily: AbTokens.fontMono,
        fontFamilyFallback: AbTokens.fontMonoFallbacks,
        fontSize: fontSize,
        fontWeight: AbTokens.bumpedWeight(FontWeight.w400, fontSize),
        devicePixelRatio: tester.view.devicePixelRatio,
      );
      return gridExtentFor(
        cells: tab.cols,
        metric: cell.charWidth,
        padding: _hPad,
      );
    }

    double renderedWidth() =>
        tester.getSize(find.byType(GhosttyTerminalView)).width;

    expect(renderedWidth(), widthFor(AbTokens.fontBody));

    const zoom = 1.5;
    // The notifier applies the new zoom to its state synchronously and only
    // then persists, so awaiting the write does not cost a frame — the pump
    // below is still the first frame that sees the new font size.
    await ProviderScope.containerOf(
      tester.element(find.byType(TerminalViewWrapper)),
    ).read(appSettingsServiceProvider.notifier).setTerminalZoom(zoom);
    await tester.pump();

    expect(
      renderedWidth(),
      widthFor(AbTokens.fontBody * zoom),
      reason: 'the grid must track the new font size on the zoom frame itself',
    );

    await tester.pumpAndSettle();
  }, variant: _macOnly);
}
