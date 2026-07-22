import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/screens/file_explorer_screen.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:antgrid/widgets/file_tree_view.dart';
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

/// Overrides that make the focused-session readiness gate (`serviceWhenReady`)
/// resolve to [session]: a focused id plus a settled [projectSessionProvider].
/// Without these, `serviceWhenReady` returns null and the screen sits on its
/// loading placeholder.
List<Override> _readySessionOverrides(ProjectSession session) => [
  selectedRegistrationIdProvider.overrideWithValue('test'),
  projectSessionProvider('test').overrideWith((ref) => session),
];

void main() {
  Future<Widget> buildTestWidget({
    required AsyncValue<FileTreeState> treeState,
    double width = 400,
  }) async {
    final session = await _buildFakeSession();
    return ProviderScope(
      overrides: [
        ..._readySessionOverrides(session),
        // Propagate an error state through the stream faithfully. (Under
        // Riverpod 2 `AsyncError.value` rethrew, so a bare `treeState.value`
        // injected the error; in Riverpod 3 `.value` is null for errors, so we
        // must emit the error explicitly to still exercise the error UI.)
        fileTreeStateProvider.overrideWith(
          (ref) => switch (treeState) {
            AsyncError(:final error, :final stackTrace) => Stream.error(
              error,
              stackTrace,
            ),
            _ => Stream.value(treeState.value ?? const FileTreeState()),
          },
        ),
        fileServiceProvider.overrideWithValue(session.fileService),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(width: width, child: const FileExplorerScreen()),
        ),
      ),
    );
  }

  group('FileExplorerScreen', () {
    testWidgets('shows loading indicator when tree state is loading', (
      tester,
    ) async {
      await tester.pumpWidget(
        await buildTestWidget(treeState: const AsyncLoading()),
      );

      expect(find.byType(AbLoading), findsOneWidget);
      expect(find.text('loading files...'), findsOneWidget);
    });

    testWidgets('shows tree view when tree data is available', (tester) async {
      const tree = FileNode(
        name: 'project',
        path: 'project',
        type: FileNodeType.directory,
        children: [
          FileNode(
            name: 'src',
            path: 'project/src',
            type: FileNodeType.directory,
          ),
          FileNode(
            name: 'README.md',
            path: 'project/README.md',
            type: FileNodeType.file,
            extension: 'md',
          ),
        ],
      );

      final state = const FileTreeState(root: tree);

      await tester.pumpWidget(
        await buildTestWidget(treeState: AsyncData(state)),
      );
      await tester.pump();

      expect(find.text('src'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
    });

    testWidgets(
      'shows loading (no red ErrorWidget, no unhandled exception) while the '
      'session is still constructing',
      (tester) async {
        useInMemoryPrefs();
        final pending = Completer<ProjectSession>(); // never completes
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              // Mid project-switch: a project is focused but its
              // ProjectSession hasn't resolved. The per-project façades throw
              // _ProjectSessionLoading in this window, so the screen (and the
              // provider graph behind it) must NOT touch them — it shows a
              // loading placeholder and raises no exception.
              selectedRegistrationIdProvider.overrideWithValue('test'),
              projectSessionProvider(
                'test',
              ).overrideWith((ref) => pending.future),
            ],
            child: const MaterialApp(
              home: Scaffold(body: FileExplorerScreen()),
            ),
          ),
        );
        await tester.pump();

        expect(tester.takeException(), isNull);
        expect(find.byType(AbLoading), findsOneWidget);
        expect(find.text('loading files...'), findsOneWidget);
      },
    );

    testWidgets('shows error state when tree fails to load', (tester) async {
      await tester.pumpWidget(
        await buildTestWidget(
          treeState: AsyncError('Connection failed', StackTrace.current),
        ),
      );
      // The override now emits the error asynchronously via Stream.error (v2's
      // AsyncError.value rethrow no longer applies under Riverpod 3), so pump
      // frames to let the session resolve and the error state reach the widget.
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('Error loading files'), findsOneWidget);
    });

    testWidgets('shows empty state when root is null', (tester) async {
      await tester.pumpWidget(
        await buildTestWidget(treeState: const AsyncData(FileTreeState())),
      );
      await tester.pump();

      expect(find.text('No files available'), findsOneWidget);
    });
  });

  group('responsive layout', () {
    const tree = FileNode(
      name: 'project',
      path: 'project',
      type: FileNodeType.directory,
      children: [
        FileNode(
          name: 'src',
          path: 'project/src',
          type: FileNodeType.directory,
        ),
        FileNode(
          name: 'main.dart',
          path: 'project/main.dart',
          type: FileNodeType.file,
          extension: 'dart',
        ),
      ],
    );

    final stateWithFile = FileTreeState(
      root: tree,
      files: const FilesPaneState(
        selectedFilePath: 'project/main.dart',
        viewingFile: FileContent(
          path: 'project/main.dart',
          content: 'void main() {}',
          size: 15,
        ),
      ),
    );

    const stateNoFile = FileTreeState(root: tree);

    testWidgets(
      'compact (400dp): when file selected, only viewer is shown (no tree)',
      (tester) async {
        await tester.pumpWidget(
          await buildTestWidget(
            treeState: AsyncData(stateWithFile),
            width: 400,
          ),
        );
        await tester.pump();

        // Viewer is present
        expect(find.byType(FileContentViewer), findsOneWidget);
        // Tree is NOT present
        expect(find.byType(FileTreeView), findsNothing);
      },
    );

    testWidgets('wide (800dp): tree and viewer are shown side by side', (
      tester,
    ) async {
      await tester.pumpWidget(
        await buildTestWidget(treeState: AsyncData(stateWithFile), width: 800),
      );
      await tester.pump();

      // Both tree and viewer are present simultaneously
      expect(find.byType(FileTreeView), findsOneWidget);
      expect(find.byType(FileContentViewer), findsOneWidget);
    });

    testWidgets(
      'wide (800dp): when no file selected, tree and empty placeholder shown',
      (tester) async {
        await tester.pumpWidget(
          await buildTestWidget(
            treeState: const AsyncData(stateNoFile),
            width: 800,
          ),
        );
        await tester.pump();

        // Tree is present
        expect(find.byType(FileTreeView), findsOneWidget);
        // Empty state placeholder text
        expect(find.text('Select a file to view'), findsOneWidget);
      },
    );

    testWidgets('compact (400dp): back button is present in viewer page', (
      tester,
    ) async {
      await tester.pumpWidget(
        await buildTestWidget(treeState: AsyncData(stateWithFile), width: 400),
      );
      await tester.pump();

      expect(find.byTooltip('Back to file tree'), findsOneWidget);
    });

    testWidgets('wide (800dp): no back button is present', (tester) async {
      await tester.pumpWidget(
        await buildTestWidget(treeState: AsyncData(stateWithFile), width: 800),
      );
      await tester.pump();

      // In wide mode the back button is not rendered.
      expect(find.byTooltip('Back to file tree'), findsNothing);
    });
  });
}
