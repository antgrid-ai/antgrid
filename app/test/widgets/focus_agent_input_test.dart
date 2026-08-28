// Pins who owns `focusAgentInputProvider`. Every "send to agent" surface
// composes somewhere other than the agent — a drawing over the preview, a
// terminal selection, a command's output — and calls this hook so the keyboard
// follows the message instead of leaving the user to click into the agent.
//
// The registration is the load-bearing half: the workspace panel's terminal
// list mounts several TerminalViewWrappers, and if one of those claimed the
// hook a send would focus a terminal the agent never sees.
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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

  /// Mounts one wrapper and hands back the container the hook is published on.
  /// [mounted] false pumps the wrapper away again, to check retraction.
  Future<ProviderContainer> pumpWrapper(
    WidgetTester tester, {
    required bool isAgentSurface,
    bool mounted = true,
  }) async {
    useInMemoryPrefs(const {});
    final prefs = await openAppSettingsPrefs();
    final service = await _makeService(addTearDown);
    final tab = _tab();
    tab.ghostty.attachExternalTransport(writeBytes: (_) => true);
    late ProviderContainer container;

    Widget wrap(Widget child) => ProviderScope(
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
          body: Consumer(
            builder: (context, ref, _) {
              container = ref.container;
              return child;
            },
          ),
        ),
      ),
    );

    await tester.pumpWidget(
      wrap(
        SizedBox(
          width: 600,
          height: 400,
          child: TerminalViewWrapper(
            tab: tab,
            terminalService: service,
            isAgentSurface: isAgentSurface,
            // super_native_extensions' test message context has no
            // ClipboardReader handler, so a real read throws rather than
            // answering "no image".
            readImage: () async => null,
          ),
        ),
      ),
    );
    // The hook is published from a post-frame callback.
    await tester.pump();

    if (!mounted) {
      await tester.pumpWidget(wrap(const SizedBox.shrink()));
      await tester.pump();
    }
    return container;
  }

  testWidgets('the agent panel terminal publishes the focus hook', (
    tester,
  ) async {
    final container = await pumpWrapper(tester, isAgentSurface: true);
    expect(container.read(focusAgentInputProvider), isNotNull);
  });

  testWidgets('calling the hook puts focus on the terminal', (tester) async {
    final container = await pumpWrapper(tester, isAgentSurface: true);

    // Somewhere else holds the keyboard first — the state a send-to-agent from
    // the preview or the file viewer leaves behind.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    container.read(focusAgentInputProvider)!.call();
    await tester.pump();

    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNotNull);
    // Inside the terminal, not merely "something got focus somewhere".
    expect(
      find.descendant(
        of: find.byType(TerminalViewWrapper),
        matching: find.byElementPredicate(
          (e) => identical(e, focused!.context),
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a workspace-panel terminal does not claim the hook', (
    tester,
  ) async {
    final container = await pumpWrapper(tester, isAgentSurface: false);
    expect(container.read(focusAgentInputProvider), isNull);
  });

  testWidgets('unmounting the agent terminal retracts the hook', (
    tester,
  ) async {
    final container = await pumpWrapper(
      tester,
      isAgentSurface: true,
      mounted: false,
    );
    expect(container.read(focusAgentInputProvider), isNull);
  });
}
