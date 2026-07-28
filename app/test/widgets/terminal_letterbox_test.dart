// Task 6: non-driver rendering + focus-gated resize claims.
//
// A terminal whose authoritative grid (cols × charWidth) is wider than the
// local viewport must horizontal-scroll (not reflow) so a viewer on a narrow
// device sees the driver's exact wrapping; a grid that fits is letterboxed
// (centered). Separately, a view that never gains focus must never claim the
// driver role by sending a resize.
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
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/prefs_test_mock.dart';

/// Opened per-test in `setUp`; the wrapper watches terminalZoom, so `_wrap`
/// must override the (default-throwing) settings provider.
late SharedPreferencesWithCache _settingsPrefs;

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
  return tab;
}

Widget _wrap(Widget child) => ProviderScope(
  overrides: [
    clientIdProvider.overrideWith((ref) async => _myClientId),
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

  testWidgets(
    'non-driver wider-than-viewport grid yields a horizontal scroll view',
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

      final horizontalScroll = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontalScroll, findsOneWidget);
      // Letterbox Align must NOT be used when the grid overflows.
      expect(find.byType(Align), findsNothing);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'non-driver fits-in-viewport grid is letterboxed (centered), no h-scroll',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final h = await _makeService(addTearDown);

      // Tiny authoritative grid (cols: 5) comfortably fits the 300px viewport →
      // amDriver == false and authWidth <= maxWidth → centered, not scrolled.
      final tab = _tab(id: 't2', cols: 5);

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

      expect(find.byType(Align), findsOneWidget);
      final horizontalScroll = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontalScroll, findsNothing);

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

      // Driver fill path uses neither the letterbox Align nor the overflow
      // horizontal scroll — both are non-driver constructs.
      expect(find.byType(Align), findsNothing);
      final horizontalScroll = find.byWidgetPredicate(
        (w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
      );
      expect(horizontalScroll, findsNothing);

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
}
