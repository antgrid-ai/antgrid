// A reconnect swaps the agent pane for its "waiting for agent" placeholder and
// mounts a fresh TerminalViewWrapper when the terminal comes back. The prompt
// box's draft — and whether the box was up — must outlive that remount.
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/terminal_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/services/terminal_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/widgets/terminal_compose_box.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
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
  final bundle = session.servicesForCheckout('main');
  registerTearDown(() async {
    await bundle.dispose();
    await session.close();
  });
  return bundle.terminalService;
}

TerminalTab _tab() => TerminalTab(
  terminalId: 'agent-1',
  name: 'agent-1',
  sessionState: TerminalSessionState.running,
  type: 'agent',
  cols: 80,
  rows: 24,
  driverClientId: null,
);

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

    Widget host({required bool showTerminal}) => ProviderScope(
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
          body: SizedBox(
            width: 400,
            height: 700,
            child: showTerminal
                ? TerminalViewWrapper(
                    tab: tab,
                    terminalService: service,
                    readImage: () async => null,
                  )
                : const Text('waiting for agent...'),
          ),
        ),
      ),
    );

    await tester.pumpWidget(host(showTerminal: true));
    await tester.pump();
    expect(find.byType(TerminalComposeBox), findsNothing);

    await tester.tap(find.byTooltip('Show keyboard'));
    await tester.pump();
    await tester.enterText(
      find.descendant(
        of: find.byType(TerminalComposeBox),
        matching: find.byType(TextField),
      ),
      'half-written prompt',
    );
    await tester.pump();

    // The reconnect: the terminal leaves the tree, then comes back.
    await tester.pumpWidget(host(showTerminal: false));
    await tester.pump();
    await tester.pumpWidget(host(showTerminal: true));
    await tester.pump();

    expect(find.byType(TerminalComposeBox), findsOneWidget);
    expect(find.text('half-written prompt'), findsOneWidget);
  });
}
