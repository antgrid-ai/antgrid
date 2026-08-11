// app/test/navigation/back_visible_tab_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/models/session_target.dart';
import 'package:antgrid/navigation/back_intent.dart';
import 'package:antgrid/navigation/nav_controller.dart';
import 'package:antgrid/navigation/nav_location.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/screens/file_explorer_screen.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/workspace_tab_bar.dart';
import '../helpers/prefs_test_mock.dart';

Future<ProjectSession> _buildFakeSession() async {
  useInMemoryPrefs();
  final t = FakeAgentTransport();
  final cache = await CachedSessionsStore.open();
  return ProjectSession(
    projectId: 'test',
    transport: t,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => t.dispose(),
  );
}

void main() {
  late ProviderContainer c;
  late ProjectSession session;

  Future<void> pumpExplorer(WidgetTester tester, WorkspaceView? visible) async {
    session = await _buildFakeSession();
    c = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
      ],
    );
    addTearDown(c.dispose);
    c.read(visibleWorkspaceViewProvider.notifier).set(visible);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 800, child: FileExplorerScreen()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('back closes the open file when the Files tab is on screen', (
    tester,
  ) async {
    await pumpExplorer(tester, WorkspaceView.files);
    session.fileService.selectFile('lib/main.dart');
    await tester.pump();

    expect(resolveBackIntent(c), isTrue);
    expect(session.fileService.currentState.files.selectedFilePath, isNull);
  });

  // The workspace panel keeps every tab mounted in an IndexedStack, so without
  // the visibility gate a back press on the Git tab would silently close a file
  // in the offscreen Files tab.
  testWidgets('back does not touch the Files tab while Git is on screen', (
    tester,
  ) async {
    await pumpExplorer(tester, WorkspaceView.git);
    session.fileService.selectFile('lib/main.dart');
    await tester.pump();

    final nav = c.read(navControllerProvider.notifier);
    nav.commit(
      NavLocation(
        target: LocalProject('a'),
        surface: WorkbenchSurface.workspace,
      ),
    );
    nav.commit(
      NavLocation(
        target: LocalProject('b'),
        surface: WorkbenchSurface.workspace,
      ),
    );

    expect(resolveBackIntent(c), isTrue);
    expect(
      session.fileService.currentState.files.selectedFilePath,
      'lib/main.dart',
    );
    // It fell through to history instead.
    expect(c.read(navControllerProvider).canForward, isTrue);
  });

  testWidgets('no content handler fires while no workspace tab is on screen', (
    tester,
  ) async {
    await pumpExplorer(tester, null);
    session.fileService.selectFile('lib/main.dart');
    await tester.pump();

    expect(resolveBackIntent(c), isFalse);
    expect(
      session.fileService.currentState.files.selectedFilePath,
      'lib/main.dart',
    );
  });
}
