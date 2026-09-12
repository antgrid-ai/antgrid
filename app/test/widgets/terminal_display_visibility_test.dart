import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/client_id.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/seeded_stream.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/services/app_settings_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/display_visibility.dart';
import 'package:antgrid/widgets/terminal_view_wrapper.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  testWidgets('split panes share demand and mounted hidden pages release it', (
    tester,
  ) async {
    useInMemoryPrefs();
    final prefs = await openAppSettingsPrefs();
    final transport = FakeAgentTransport();
    final session = ProjectSession(
      projectId: 'p',
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: await CachedSessionsStore.open(),
      onClose: transport.dispose,
    );
    final service = session.terminalService;
    service.activate();
    addTearDown(session.close);
    transport.emit('agent:status', {
      'projectId': 'p',
      'terminals': [
        {'terminalId': 'a', 'name': 'a', 'running': true},
      ],
    });
    await tester.pump();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clientIdProvider.overrideWith((ref) async => 'viewer'),
          agentTerminalProvider.overrideWith((ref) => null),
          terminalStateProvider.overrideWith(
            (ref) =>
                seededStream(() => service.currentState, service.stateStream),
          ),
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
                final tab = ref.watch(terminalStateProvider).value?.tabs['a'];
                if (tab == null) return const SizedBox.shrink();
                return Row(
                  children: [
                    Expanded(
                      child: DisplayVisibility(
                        child: TerminalViewWrapper(
                          key: const ValueKey('agent'),
                          tab: tab,
                          terminalService: service,
                        ),
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: 0,
                        children: [
                          DisplayVisibility(
                            workspaceView: WorkspaceView.terminals,
                            child: TerminalViewWrapper(
                              key: const ValueKey('pinned'),
                              tab: tab,
                              terminalService: service,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Row).first),
    );
    List<Map<String, dynamic>> messages(String type) =>
        transport.sent.where((m) => m['type'] == 'terminal:$type').toList();
    expect(messages('subscribe'), hasLength(1));
    final request = messages('subscribe').single;
    transport.emit('terminal:subscribed', {
      'terminalId': 'a',
      'runId': 'run',
      'attachmentId': 'attachment',
      'version': 1,
      'requestId': request['requestId'],
    });
    await tester.pump();
    transport.emit('terminal:frame', {
      'terminalId': 'a',
      'runId': 'run',
      'attachmentId': 'attachment',
      'version': 1,
      'sequence': 1,
      'revision': 1,
      'cols': 80,
      'rows': 24,
      'ansi': 'cached screen',
      'syncTimedOut': false,
      'history': {
        'epoch': 1,
        'firstRowId': 0,
        'nextRowId': 0,
        'status': 'recording',
      },
    });
    await tester.pump();
    expect(service.canSendInput('a'), isTrue);

    container
        .read(visibleWorkspaceViewProvider.notifier)
        .set(WorkspaceView.terminals);
    await tester.pump();
    await tester.pump();
    container.read(agentSurfaceVisibleProvider.notifier).set(false);
    await tester.pump();
    await tester.pump();
    expect(messages('unsubscribe'), isEmpty);
    expect(messages('subscribe'), hasLength(1));
    container.read(visibleWorkspaceViewProvider.notifier).set(null);
    await tester.pump();
    await tester.pump();
    expect(find.byType(TerminalViewWrapper), findsNWidgets(2));
    expect(messages('unsubscribe'), hasLength(1));
    expect(service.canSendInput('a'), isFalse);

    container.read(agentSurfaceVisibleProvider.notifier).set(true);
    await tester.pump();
    await tester.pump();
    expect(messages('subscribe'), hasLength(2));
    expect(
      service.currentState.tabs['a']!.ghostty.plainText,
      contains('cached screen'),
    );
    expect(service.sendInput('a', 'x'), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
