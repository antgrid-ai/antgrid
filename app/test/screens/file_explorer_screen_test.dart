import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/design/widgets/ab_icon.dart';
import 'package:antgrid/design/widgets/ab_toolbar.dart';
import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/screens/file_explorer_screen.dart';
import 'package:antgrid/services/file_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/file_content_viewer.dart';
import 'package:antgrid/widgets/file_tree_view.dart';
import 'package:antgrid/widgets/file_search_bar.dart';
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
  group('FileExplorerScreen filter box', () {
    /// Same readiness overrides as [buildTestWidget], but the transport is
    /// handed back so a test can read the outbound `file:find` and answer it.
    /// [includeIgnoredInTree] simulates the "Hide git-ignored files" setting
    /// having already been applied to the tree's FileService (A5: the filter
    /// reads the tree's effective setting, not a constant).
    Future<(FakeAgentTransport, Widget)> buildFilterWidget({
      bool includeIgnoredInTree = true,
    }) async {
      useInMemoryPrefs();
      final t = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      final session = ProjectSession(
        projectId: 'test',
        transport: t,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => t.dispose(),
      );
      session.fileService.setIncludeIgnoredInTree(includeIgnoredInTree);
      const tree = FileNode(
        name: '',
        path: '',
        type: FileNodeType.directory,
        children: [
          FileNode(name: 'lib', path: 'lib', type: FileNodeType.directory),
        ],
      );
      return (
        t,
        ProviderScope(
          overrides: [
            ..._readySessionOverrides(session),
            fileTreeStateProvider.overrideWith(
              (ref) => Stream.value(const FileTreeState(root: tree)),
            ),
            fileServiceProvider.overrideWithValue(session.fileService),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SizedBox(width: 800, child: FileExplorerScreen()),
            ),
          ),
        ),
      );
    }

    Finder filterInput() => find.descendant(
      of: find.byType(FileSearchBar),
      matching: find.byType(EditableText),
    );

    Future<Map<String, dynamic>> typeFilter(
      WidgetTester tester,
      FakeAgentTransport t,
      String query,
    ) async {
      await tester.enterText(filterInput(), query);
      // Only FileService.findDebounce: FileSearchBar is mounted with
      // Duration.zero so the two debounces do not stack.
      await tester.pump(FileService.findDebounce + const Duration(milliseconds: 20));
      return t.sent.lastWhere((m) => m['type'] == 'file:find');
    }

    testWidgets('the filter glyph starts in the chevron column of the tree', (
      tester,
    ) async {
      final (_, widget) = await buildFilterWidget();
      await tester.pumpWidget(widget);
      await tester.pump();

      // LEFT edges, not centres: the two glyphs are different widths, and a
      // chevron is text whose advance the test font exaggerates, so a centre
      // comparison would assert the font rather than the layout. The inset
      // itself is what has to agree — AbListRow's own horizontal padding on
      // one side, the toolbar's padding plus its centre-slot gap on the other.
      final icon = find.descendant(
        of: find.byType(FileSearchBar),
        matching: find.byType(AbIcon),
      );
      expect(
        tester.getTopLeft(icon.first).dx,
        tester.getTopLeft(find.text('▶ ').first).dx,
      );
    });

    testWidgets('the filter shares the action row rather than taking its own', (
      tester,
    ) async {
      final (_, widget) = await buildFilterWidget();
      await tester.pumpWidget(widget);
      await tester.pump();

      // Stacked, the filter's magnifier sat directly under the toolbar's own
      // — which searches file CONTENTS, not names — and the tree lost a row
      // of height to say it twice.
      expect(
        find.descendant(
          of: find.byType(AbToolbar),
          matching: find.byType(FileSearchBar),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'sends includeIgnored: true so the filter agrees with the tree it filters',
      (tester) async {
        final (t, widget) = await buildFilterWidget();
        await tester.pumpWidget(widget);
        await tester.pump();

        final sent = await typeFilter(tester, t, 'need');
        expect(sent['query'], 'need');
        // D10's deliberate asymmetry: @-mentions send false, the tree's own
        // filter sends true. Nothing else pins this direction.
        expect(sent['includeIgnored'], isTrue);
        // Answered, or the PendingReply timeout outlives the widget tree.
        t.emit('file:find-result', {
          'projectId': 'test',
          'requestId': sent['requestId'],
          'entries': const [],
          'truncated': false,
          'engine': 'git-ls-files',
        });
        await tester.pumpAndSettle();
      },
    );

    testWidgets(
      'follows the tree when "Hide git-ignored files" is on (A5)',
      (tester) async {
        final (t, widget) = await buildFilterWidget(
          includeIgnoredInTree: false,
        );
        await tester.pumpWidget(widget);
        await tester.pump();

        final sent = await typeFilter(tester, t, 'need');
        expect(sent['includeIgnored'], isFalse);
        t.emit('file:find-result', {
          'projectId': 'test',
          'requestId': sent['requestId'],
          'entries': const [],
          'truncated': false,
          'engine': 'git-ls-files',
        });
        await tester.pumpAndSettle();
      },
    );

    testWidgets('renders Searching…, then the ranked rows', (tester) async {
      final (t, widget) = await buildFilterWidget();
      await tester.pumpWidget(widget);
      await tester.pump();

      await tester.enterText(filterInput(), 'need');
      await tester.pump();
      expect(find.text('Searching…'), findsOneWidget);

      await tester.pump(FileService.findDebounce + const Duration(milliseconds: 20));
      final sent = t.sent.lastWhere((m) => m['type'] == 'file:find');
      t.emit('file:find-result', {
        'projectId': 'test',
        'requestId': sent['requestId'],
        'entries': [
          {'path': 'lib/needle.dart', 'isDir': false},
        ],
        'truncated': false,
        'engine': 'git-ls-files',
      });
      await tester.pumpAndSettle();

      expect(find.text('lib/needle.dart'), findsOneWidget);
      expect(find.text('Searching…'), findsNothing);
    });

    testWidgets('an empty answer says so; an errored one says it failed', (
      tester,
    ) async {
      final (t, widget) = await buildFilterWidget();
      await tester.pumpWidget(widget);
      await tester.pump();

      var sent = await typeFilter(tester, t, 'nope');
      t.emit('file:find-result', {
        'projectId': 'test',
        'requestId': sent['requestId'],
        'entries': const [],
        'truncated': false,
        'engine': 'git-ls-files',
      });
      await tester.pumpAndSettle();
      expect(find.text('No matching files'), findsOneWidget);

      sent = await typeFilter(tester, t, 'boom');
      t.emit('file:find-result', {
        'projectId': 'test',
        'requestId': sent['requestId'],
        'entries': const [],
        'truncated': true,
        'engine': 'none',
        'error': 'file listing timed out',
      });
      await tester.pumpAndSettle();
      // A killed listing answers with zero entries too — rendering it as
      // "No matching files" had the user retrying a search that broke.
      expect(find.text('No matching files'), findsNothing);
      expect(
        find.textContaining('file listing timed out'),
        findsOneWidget,
      );
    });

    testWidgets('a directory row reveals it in the tree and clears the filter', (
      tester,
    ) async {
      final (t, widget) = await buildFilterWidget();
      await tester.pumpWidget(widget);
      await tester.pump();

      final sent = await typeFilter(tester, t, 'lib');
      t.emit('file:find-result', {
        'projectId': 'test',
        'requestId': sent['requestId'],
        'entries': [
          {'path': 'lib/models', 'isDir': true},
        ],
        'truncated': false,
        'engine': 'git-ls-files',
      });
      await tester.pumpAndSettle();

      // The filter field sits in the action row directly above these results,
      // so the caret handle `enterText` leaves behind is painted over the
      // first one and swallows the tap. It reaches further right here than on
      // a device — the test font gives every glyph the same wide advance — so
      // it lands on the row's centre rather than beside it.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();

      await tester.tap(find.text('lib/models'));
      await tester.pumpAndSettle();

      final revealed = t.sent
          .where((m) => m['type'] == 'file:tree:children:request')
          .expand((m) => (m['paths'] as List).cast<String>())
          .toSet();
      expect(revealed, containsAll(<String>['lib', 'lib/models']));
      // The results list is gone — the tree is back.
      expect(find.text('lib/models'), findsNothing);
      expect(find.byType(FileTreeView), findsOneWidget);
    });
  });
}
