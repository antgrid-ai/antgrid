// A reconnect swaps the agent pane for its "waiting for agent" placeholder and
// mounts a fresh TerminalViewWrapper when the terminal comes back. The prompt
// box's draft — and whether the box was up — must outlive that remount.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/widgets/terminal_compose_box.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferencesWithCache;

import '../helpers/fake_agent_transport.dart';
import '../helpers/fake_project_session.dart';
import '../helpers/prefs_test_mock.dart';

Future<TerminalService> _makeService(
  void Function(Future<void> Function()) registerTearDown,
) async {
  final transport = FakeAgentTransport();
  final session = await newFakeProjectSession(transport);
  final bundle = session.servicesForCheckout('main');
  registerTearDown(() async {
    await bundle.dispose();
    await session.close();
  });
  return bundle.terminalService;
}

TerminalTab _tab([String id = 'agent-1']) => TerminalTab(
  terminalId: id,
  name: id,
  sessionState: TerminalSessionState.running,
  type: 'agent',
  cols: 80,
  rows: 24,
  driverClientId: null,
);

Widget _host(SharedPreferencesWithCache prefs, Widget child) => ProviderScope(
  overrides: [
    clientIdProvider.overrideWith((ref) async => 'this-install'),
    agentTerminalProvider.overrideWith((ref) => null),
    appSettingsServiceProvider.overrideWith(
      () => AppSettingsService(prefs, AppSettings.fromPrefs(prefs)),
    ),
  ],
  child: MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
    ),
    home: Scaffold(
      body: SizedBox(width: 400, height: 700, child: child),
    ),
  ),
);

Future<void> _typeDraft(WidgetTester tester, String text) async {
  await tester.tap(find.byTooltip('Show keyboard'));
  await tester.pump();
  await tester.enterText(
    find.descendant(
      of: find.byType(TerminalComposeBox),
      matching: find.byType(TextField),
    ),
    text,
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => debugHasPhysicalKeyboardOverride = false);
  tearDown(() => debugHasPhysicalKeyboardOverride = null);

  testWidgets('the draft and the open box survive a remount', (tester) async {
    useInMemoryPrefs(const {});
    final prefs = await openAppSettingsPrefs();
    final service = await _makeService(addTearDown);
    final tab = _tab();
    tab.ghostty.attachExternalTransport(writeBytes: (_) => true);

    Widget host({required bool showTerminal}) => _host(
      prefs,
      showTerminal
          ? TerminalViewWrapper(
              tab: tab,
              terminalService: service,
              readImage: () async => null,
            )
          : const Text('waiting for agent...'),
    );

    await tester.pumpWidget(host(showTerminal: true));
    await tester.pump();
    expect(find.byType(TerminalComposeBox), findsNothing);
    await _typeDraft(tester, 'half-written prompt');

    // The reconnect: the terminal leaves the tree, then comes back.
    await tester.pumpWidget(host(showTerminal: false));
    await tester.pump();
    await tester.pumpWidget(host(showTerminal: true));
    await tester.pump();

    expect(find.byType(TerminalComposeBox), findsOneWidget);
    expect(find.text('half-written prompt'), findsOneWidget);
  });

  // The wrapper keeps its State when handed another terminal (didUpdateWidget
  // rewires input for exactly that), so the draft must follow the terminal,
  // not the State.
  testWidgets('a wrapper handed another terminal shows that terminal draft', (
    tester,
  ) async {
    useInMemoryPrefs(const {});
    final prefs = await openAppSettingsPrefs();
    final service = await _makeService(addTearDown);
    final a = _tab('agent-1');
    final b = _tab('agent-2');
    for (final t in [a, b]) {
      t.ghostty.attachExternalTransport(writeBytes: (_) => true);
    }

    Widget host(TerminalTab tab) => _host(
      prefs,
      TerminalViewWrapper(
        tab: tab,
        terminalService: service,
        readImage: () async => null,
      ),
    );

    await tester.pumpWidget(host(a));
    await tester.pump();
    await _typeDraft(tester, 'draft for one');

    await tester.pumpWidget(host(b));
    await tester.pump();
    expect(find.byType(TerminalComposeBox), findsNothing);
    expect(find.text('draft for one'), findsNothing);

    await tester.pumpWidget(host(a));
    await tester.pump();
    expect(find.byType(TerminalComposeBox), findsOneWidget);
    expect(find.text('draft for one'), findsOneWidget);
  });
}
