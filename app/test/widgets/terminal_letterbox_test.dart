// Task 6: non-driver rendering + focus-gated resize claims.
//
// A terminal whose authoritative grid (cols × charWidth) is wider than the
// local viewport must be SCALED DOWN whole -- never reflowed, never
// scrolled -- so a viewer on a narrow device sees the driver's exact
// wrapping. Rows are pinned for the same reason as cols, so the scale
// applies to BOTH axes; a grid that fits is letterboxed (centered) at its
// natural size, since the scale never enlarges. Separately, a view that
// never gains focus must never claim the driver role by sending a resize.
import 'dart:async';

import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/prefs_test_mock.dart';

/// Opened per-test in `setUp`; the wrapper watches terminalZoom, so `_wrap`
/// must override the (default-throwing) settings provider.
late SharedPreferencesWithCache _settingsPrefs;

/// Sub-pixel slack for geometry read back through a layout and a transform.
const _epsilon = 0.5;

/// A scroll view the WRAPPER put above the terminal.
///
/// `GhosttyTerminalView` owns one of its own for its scrollback, so the
/// contract can only be stated as an ancestor: the non-driver path scales its
/// grid down rather than scrolling it, on BOTH axes, because a scroll view
/// wrapped around the terminal loses every drag to that inner scrollable and
/// strands the rows it exists to reveal.
final _wrappingScrollView = find.ancestor(
  of: find.byType(GhosttyTerminalView),
  matching: find.byType(SingleChildScrollView),
);

const _myClientId = 'this-install';
const _otherClientId = 'some-other-device';

/// Builds a real (local) [ProjectSession] + [TerminalService] over a
/// [FakeAgentTransport] whose outbound `sent` list the tests inspect.
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
  required int cols,
  String? driverClientId = _otherClientId,
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
  // TerminalTab builds its controller eagerly, and these tabs never enter
  // TerminalService's own map — so nothing else disposes them and each one is a
  // leaked native VT for the life of the test process.
  addTearDown(() async => tab.ghostty.dispose());
  return tab;
}

/// [clientId] lets a test hold the provider in `AsyncLoading`: the real one
/// reads SharedPreferences, so a terminal can be on screen before it resolves,
/// and the load→data transition is the rebuild the wrapper's retry depends on.
Widget _wrap(Widget child, {Future<String>? clientId}) => ProviderScope(
  overrides: [
    clientIdProvider.overrideWith(
      (ref) => clientId ?? Future.value(_myClientId),
    ),
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

  // Every test here overrides the platform and clears it as its last statement,
  // which a failing `expect` skips — leaking the override into every test after
  // it and turning one real failure into a cascade of platform-dependent ones.
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets(
    'non-driver grid larger than the viewport is scaled down, not scrolled',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);

      // Driven by ANOTHER device, grid far wider than the 300px viewport →
      // amDriver == false and the authoritative width overflows.
      final tab = _tab(id: 't1', cols: 200);

      await tester.pumpWidget(
        _wrap(
          Center(
            child: SizedBox(
              width: 300,
              height: 400,
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No scroll view on EITHER axis: a vertical one is unreachable behind
      // GhosttyTerminalView's own drag handlers, and a horizontal one hides
      // columns the driver can see.
      expect(_wrappingScrollView, findsNothing);

      // Laid out at the driver's geometry...
      final laidOut = tester.getSize(find.byType(GhosttyTerminalView));
      expect(laidOut.width, greaterThan(300));

      // ...and painted scaled down, wholly inside the viewport, so every row
      // and column the driver has is on screen with nothing to scroll to.
      final painted = tester.getRect(find.byType(GhosttyTerminalView));
      expect(painted.width, lessThan(laidOut.width));
      expect(painted.width, lessThanOrEqualTo(300 + _epsilon));
      expect(painted.height, lessThanOrEqualTo(400 + _epsilon));

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'non-driver fits-in-viewport grid is letterboxed (centered), unscaled',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);

      // Tiny authoritative grid (cols: 5, rows: 24) inside a viewport that
      // clears it on BOTH axes -- 400px would not hold 24 rows, and the
      // vertical axis binds the scale just as the horizontal one does. Both
      // dimensions stay inside the 800x600 test surface, or the wrapper's own
      // rect runs off screen and centring cannot be read off it.
      final tab = _tab(id: 't2', cols: 5);

      await tester.pumpWidget(
        _wrap(
          Center(
            child: SizedBox(
              width: 600,
              height: 560,
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_wrappingScrollView, findsNothing);

      // The scale never ENLARGES, so a grid this small is painted at exactly
      // its natural size and merely centred: a plain letterbox on both axes.
      final laidOut = tester.getSize(find.byType(GhosttyTerminalView));
      final painted = tester.getRect(find.byType(GhosttyTerminalView));
      expect(painted.width, closeTo(laidOut.width, _epsilon));
      expect(painted.height, closeTo(laidOut.height, _epsilon));

      // Centred inside the letterbox box itself, not the wrapper: the wrapper
      // also carries chrome, so its centre is not the box the child aligns in.
      final box = tester.getRect(find.byType(FittedBox));
      expect(painted.center.dx, closeTo(box.center.dx, _epsilon));
      expect(painted.center.dy, closeTo(box.center.dy, _epsilon));

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'a view that never gains focus sends no terminal:resize (no claim)',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      // Stamp a clientId so a resize WOULD actually be sent if a claim fired —
      // makes the "no send" assertion meaningful rather than vacuous.
      h.service.setClientId(_myClientId);

      // Non-driver tab → amDriver == false; the only send path is the
      // focus-gated claim. ExcludeFocus makes the whole subtree unfocusable, so
      // the terminal view's `autofocus: true` is a no-op and `_locallyActive`
      // stays false — deterministically exercising the unfocused path.
      final tab = _tab(id: 't3', cols: 200);

      await tester.pumpWidget(
        _wrap(
          ExcludeFocus(
            child: SizedBox(
              width: 300,
              height: 400,
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Drain the 100ms sendResize debounce so any (erroneous) claim would land.
      await tester.pump(const Duration(milliseconds: 150));

      final resizes = h.transport.sent
          .where((m) => m['type'] == 'terminal:resize')
          .toList();
      expect(resizes, isEmpty);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'an unclaimed (no driver yet) view drives without focus and sends a resize',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      h.service.setClientId(_myClientId);

      // driverClientId == null → no device owns this terminal yet. A single
      // client must resize its PTY immediately, even before keyboard focus
      // lands in the terminal. ExcludeFocus keeps `_locallyActive` false, so
      // this exercises the unfocused-but-unclaimed path that previously dropped
      // every window resize until an app-switch forced a focus claim.
      final tab = _tab(id: 't5', cols: 80, driverClientId: null);

      await tester.pumpWidget(
        _wrap(
          ExcludeFocus(
            child: SizedBox(
              width: 300,
              height: 400,
              child: TerminalViewWrapper(tab: tab, terminalService: h.service),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));

      final resizes = h.transport.sent
          .where((m) => m['type'] == 'terminal:resize')
          .toList();
      expect(resizes, isNotEmpty);
      expect(resizes.last['clientId'], _myClientId);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'unclaimed + unfocused renders the driver fill path, not a fixed-width '
    'letterbox (content tracks the panel)',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      h.service.setClientId(_myClientId);

      // Exactly the user-reported repro: a freshly-created session that never
      // got keyboard focus (driverClientId == null). Before the fix this fell
      // into the non-driver branch — a fixed-width SizedBox centered by an
      // Align — so the panel grew (letterbox area) while the content stayed
      // pinned at tab.cols. An unclaimed terminal must instead drive and fill
      // the viewport without needing focus. (Assert on the widget tree, not
      // engine cols: the headless engine does not run its grid layout without
      // a focus context — see the letterbox tests above, which do the same.)
      final tab = _tab(id: 't7', cols: 5, driverClientId: null);

      await tester.pumpWidget(
        _wrap(
          ExcludeFocus(
            child: Center(
              child: SizedBox(
                width: 300,
                height: 400,
                child: TerminalViewWrapper(
                  tab: tab,
                  terminalService: h.service,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The driver fill path uses no scaler at all. That is the non-driver
      // construct, and a driver whose content were scaled would be typing
      // into a grid that does not match the size it renders at.
      expect(find.byType(FittedBox), findsNothing);
      expect(_wrappingScrollView, findsNothing);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'driver: resizing the panel re-syncs the engine grid to the new width',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      h.service.setClientId(_myClientId);

      // This install owns the terminal → amDriver == true → driver render path
      // (the freeze). Reproduces the user-reported bug: the panel resizes but
      // the terminal *content* (engine grid) stays at the old width.
      final tab = _tab(id: 't6', cols: 80, driverClientId: _myClientId);

      Widget atWidth(double w) => _wrap(
        Center(
          child: SizedBox(
            width: w,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
        ),
      );

      await tester.pumpWidget(atWidth(300));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      final colsAt300 = tab.ghostty.cols;

      // Grow the panel and let the grid-freeze settle delay (150ms) elapse.
      await tester.pumpWidget(atWidth(600));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 200));
      final colsAt600 = tab.ghostty.cols;

      expect(
        colsAt600,
        greaterThan(colsAt300),
        reason:
            'engine grid must widen with the panel; stuck at $colsAt300 means '
            'the content never re-rendered to the new size',
      );

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'desktop autofocus alone does not claim an already-driven terminal',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      h.service.setClientId(_myClientId);

      final tab = _tab(id: 't4', cols: 200);

      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));

      final resizes = h.transport.sent
          .where((m) => m['type'] == 'terminal:resize')
          .toList();
      expect(resizes, isEmpty);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('desktop pointer activation claims by sending terminal:resize', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final h = await _makeService(addTearDown);
    h.service.setClientId(_myClientId);

    final tab = _tab(id: 't4b', cols: 200);

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 300,
          height: 400,
          child: TerminalViewWrapper(tab: tab, terminalService: h.service),
        ),
      ),
    );
    await tester.pumpAndSettle();
    h.transport.sent.clear();

    await tester.tap(find.byType(TerminalViewWrapper));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 150));

    final resizes = h.transport.sent
        .where((m) => m['type'] == 'terminal:resize')
        .toList();
    expect(resizes, isNotEmpty);
    expect(resizes.last['clientId'], _myClientId);
    expect(resizes.last['baseDriverClientId'], _otherClientId);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'driver grid settles to a grown panel while the wrapper keeps rebuilding',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      h.service.setClientId(_myClientId);

      // The grid-freeze delay measures quiet on the SIZE, not on rebuilds:
      // LayoutBuilder re-runs its builder on every parent rebuild, so re-arming
      // per rebuild lets a wrapper rebuilding faster than the delay (a
      // streaming agent) hold the timer off forever and strand the grid at the
      // pre-resize width — content clipped at the stale column with dead space
      // beside it.
      final tab = _tab(id: 't8', cols: 80, driverClientId: _myClientId);

      final width = ValueNotifier<double>(300);
      final rebuilds = ValueNotifier<int>(0);
      addTearDown(() {
        width.dispose();
        rebuilds.dispose();
      });

      await tester.pumpWidget(
        _wrap(
          AnimatedBuilder(
            animation: Listenable.merge([width, rebuilds]),
            builder: (context, _) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width.value,
                height: 400,
                child: TerminalViewWrapper(
                  tab: tab,
                  terminalService: h.service,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(GhosttyTerminalView)).width,
        closeTo(300, _epsilon),
      );

      width.value = 600;
      for (var i = 0; i < 12; i++) {
        rebuilds.value++;
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        tester.getSize(find.byType(GhosttyTerminalView)).width,
        closeTo(600, _epsilon),
      );

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'a resize dropped for a not-yet-resolved client id is retried, not booked',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);
      // Deliberately unresolved: the terminal is on screen before the
      // per-install id is read off disk, which is the startup order the wrapper
      // has to survive. `sendResize` drops those, and booking one as sent would
      // leave the PTY at its spawn geometry with nothing left to trigger a
      // re-send.
      final clientId = Completer<String>();
      final tab = _tab(id: 't9', cols: 80, driverClientId: null);

      // Built ONCE. Completing the id below is the only thing that rebuilds
      // this tree, so the test fails if the wrapper stops watching
      // `clientIdProvider` — pumping a second tree by hand would supply the
      // rebuild the production path is supposed to provide for itself.
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 300,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
          clientId: clientId.future,
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));
      expect(
        h.transport.sent.where((m) => m['type'] == 'terminal:resize'),
        isEmpty,
        reason: 'no client id yet, so nothing can be stamped and sent',
      );

      // The id lands: the size is still unsent, so the same geometry must go
      // out now rather than wait for a panel resize.
      h.service.setClientId(_myClientId);
      clientId.complete(_myClientId);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 150));

      final resizes = h.transport.sent
          .where((m) => m['type'] == 'terminal:resize')
          .toList();
      expect(resizes, isNotEmpty);
      expect(resizes.last['clientId'], _myClientId);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets('a sizeEpoch bump reopens the resize gate at an unchanged size', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final h = await _makeService(addTearDown);
    h.service.setClientId(_myClientId);
    // Drives its own PTY, so the driver branch is live and the settled size is
    // what the resize is derived from.
    var tab = _tab(id: 't10', cols: 80, driverClientId: _myClientId);

    Future<void> show() async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 500,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    await show();
    expect(
      h.transport.sent.where((m) => m['type'] == 'terminal:resize'),
      isNotEmpty,
    );

    // Panel unchanged: the booked size still stands, so nothing goes out. This
    // is the gate that strands a respawned PTY, and it has to be shut here for
    // the bump below to prove anything.
    h.transport.sent.clear();
    await show();
    expect(
      h.transport.sent.where((m) => m['type'] == 'terminal:resize'),
      isEmpty,
    );

    // The service reports the geometry as no longer trustworthy — a re-drive
    // or a respawn. The panel STILL has not moved, so the bump is the only
    // thing that can put the size back on the wire.
    tab = tab.copyWith(sizeEpoch: tab.sizeEpoch + 1);
    await show();

    final resizes = h.transport.sent
        .where((m) => m['type'] == 'terminal:resize')
        .toList();
    expect(resizes, isNotEmpty);
    expect(resizes.last['clientId'], _myClientId);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('swapping which terminal an unkeyed wrapper shows re-sends', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final h = await _makeService(addTearDown);
    h.service.setClientId(_myClientId);

    // Only `terminal_screen` keys the wrapper by terminalId; the pinned pane,
    // the detail view and the setup banner all mount it unkeyed, so this swap
    // REUSES one State. Both tabs drive, sit at the same epoch and are shown at
    // the same panel size — so every gate the wrapper carries per-PTY reads as
    // "already sent" unless the swap itself retires them.
    final a = _tab(id: 'swap-a', cols: 80, driverClientId: _myClientId);
    final b = _tab(id: 'swap-b', cols: 80, driverClientId: _myClientId);

    Future<void> show(TerminalTab tab) async {
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 500,
            height: 400,
            child: TerminalViewWrapper(tab: tab, terminalService: h.service),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    await show(a);
    expect(
      h.transport.sent.where((m) => m['type'] == 'terminal:resize'),
      isNotEmpty,
    );

    h.transport.sent.clear();
    await show(b);

    final resizes = h.transport.sent
        .where((m) => m['type'] == 'terminal:resize')
        .toList();
    expect(
      resizes.map((m) => m['terminalId']),
      contains('swap-b'),
      reason: "the new PTY has never been told this panel's grid",
    );

    debugDefaultTargetPlatformOverride = null;
  });
}
