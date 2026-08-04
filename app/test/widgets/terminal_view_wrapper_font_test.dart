// The terminal's font must follow the app's UI Size setting. The app injects
// uiScale as a MediaQuery textScaler, but GhosttyTerminalView lays out its own
// TextPainters — the ambient scaler never reaches them — so the wrapper must
// pre-scale the fontSize it passes down. These tests pin that pass-through.
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:antgrid/widgets/terminal_detail_view.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/prefs_test_mock.dart';

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

TerminalTab _tab(String id) {
  final tab = TerminalTab(
    terminalId: id,
    name: id,
    sessionState: TerminalSessionState.running,
    type: 'service',
    cols: 80,
    rows: 24,
    driverClientId: null,
  );
  tab.ghostty.attachExternalTransport(writeBytes: (_) => true);
  return tab;
}

Widget _wrap(
  Widget child, {
  required double textScale,
  required SharedPreferencesWithCache prefs,
}) => ProviderScope(
  overrides: [
    clientIdProvider.overrideWith((ref) async => 'this-install'),
    agentTerminalProvider.overrideWith((ref) => null),
    // The wrapper watches terminalZoom; the default provider impl throws.
    appSettingsServiceProvider.overrideWith(
      () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
    ),
  ],
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    home: Scaffold(
      // Inject the scaler the way the app's uiScale setting does — via
      // MediaQuery above the wrapper.
      body: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child,
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<GhosttyTerminalView> pumpAtScale(
    WidgetTester tester,
    double scale,
    String tabId, {
    Map<String, Object> seedPrefs = const {},
  }) async {
    useInMemoryPrefs(seedPrefs);
    final prefs = await openAppSettingsPrefs();
    final service = await _makeService(addTearDown);
    final tab = _tab(tabId);
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          height: 400,
          child: TerminalViewWrapper(tab: tab, terminalService: service),
        ),
        textScale: scale,
        prefs: prefs,
      ),
    );
    await tester.pumpAndSettle();
    return tester.widget<GhosttyTerminalView>(find.byType(GhosttyTerminalView));
  }

  testWidgets('terminal fontSize follows the MediaQuery textScaler', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final view = await pumpAtScale(tester, 1.3, 't-scaled');
    expect(view.fontSize, AbTokens.fontBody * 1.3);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('terminal fontSize is the base token at scale 1.0', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final view = await pumpAtScale(tester, 1.0, 't-base');
    expect(view.fontSize, AbTokens.fontBody);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('persisted terminalZoom multiplies the scaled fontSize', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final view = await pumpAtScale(
      tester,
      1.3,
      't-zoomed',
      seedPrefs: {'antgrid.terminal_zoom.v1': 1.5},
    );
    expect(view.fontSize, closeTo(AbTokens.fontBody * 1.3 * 1.5, 1e-9));

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('terminalZoom at 1.5 with no textScaler scales fontBody alone', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    final view = await pumpAtScale(
      tester,
      1.0,
      't-zoom-only',
      seedPrefs: {'antgrid.terminal_zoom.v1': 1.5},
    );
    expect(view.fontSize, closeTo(AbTokens.fontBody * 1.5, 1e-9));

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('terminal detail keeps status and delete in the title row', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    useInMemoryPrefs();
    final prefs = await openAppSettingsPrefs();
    final service = await _makeService(addTearDown);
    final tab = _tab('Terminal 1');
    var deleted = false;

    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          height: 400,
          child: TerminalDetailView(
            tab: tab,
            terminalService: service,
            onBack: () {},
            onDelete: () => deleted = true,
          ),
        ),
        textScale: 1,
        prefs: prefs,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Delete'), findsOneWidget);
    expect(find.byType(AbStatusDot), findsOneWidget);
    expect(find.text('Terminal 1'), findsOneWidget);
    expect(find.text('Running'), findsNothing);

    await tester.tap(find.byTooltip('Delete'));
    expect(deleted, isTrue);

    debugDefaultTargetPlatformOverride = null;
  });
}
