import 'package:antgrid/models/file_tree_models.dart';
import 'package:antgrid/models/workspace_view.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/providers.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/screens/file_explorer_screen.dart';
import 'package:antgrid/services/file_service.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/carbon_guard.dart';
import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

const _tree = FileNode(
  name: 'project',
  path: 'project',
  type: FileNodeType.directory,
  children: [
    FileNode(name: 'src', path: 'project/src', type: FileNodeType.directory),
    FileNode(
      name: 'README.md',
      path: 'project/README.md',
      type: FileNodeType.file,
      extension: 'md',
    ),
  ],
);

Finder _button(String label) => find.byWidgetPredicate(
  (w) => w is CarbonButton && w.semanticLabel == label,
  description: 'CarbonButton "$label"',
);

Future<Widget> _host(
  AsyncValue<FileTreeState> state, {
  double width = 900,
  Brightness brightness = Brightness.light,
  FakeAgentTransport? transport,
}) async {
  useInMemoryPrefs();
  transport ??= FakeAgentTransport();
  final fake = transport;
  final cache = await CachedSessionsStore.open();
  final session = ProjectSession(
    projectId: 'test',
    transport: fake,
    mode: ProjectSessionMode.local,
    cachedSessionsStore: cache,
    onClose: () async => fake.dispose(),
  );
  return ProviderScope(
    overrides: [
      selectedRegistrationIdProvider.overrideWithValue('test'),
      // Off screen the explorer mutes its subtree's TickerMode, which also
      // pauses Riverpod listeners below it: the search panel would never see
      // its state arrive.
      visibleWorkspaceViewProvider.overrideWith(
        () => ValueController(WorkspaceView.files),
      ),
      projectSessionProvider('test').overrideWith((ref) => session),
      fileTreeStateProvider.overrideWith(
        (ref) => switch (state) {
          AsyncError(:final error, :final stackTrace) => Stream.error(
            error,
            stackTrace,
          ),
          _ => Stream.value(state.value ?? const FileTreeState()),
        },
      ),
      fileServiceProvider.overrideWithValue(session.fileService),
    ],
    child: MaterialApp(
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      themeAnimationDuration: Duration.zero,
      theme: ThemeData(brightness: Brightness.light),
      darkTheme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: SizedBox(width: width, child: const FileExplorerScreen()),
      ),
    ),
  );
}

void main() {
  for (final brightness in Brightness.values) {
    for (final touch in [false, true]) {
      final name = '${brightness.name} ${touch ? 'touch' : 'desktop'}';

      testWidgets('loaded tree has no Ab widget ($name)', (tester) async {
        debugDefaultTargetPlatformOverride = touch
            ? TargetPlatform.android
            : TargetPlatform.windows;
        await tester.pumpWidget(
          await _host(
            const AsyncData(FileTreeState(root: _tree)),
            brightness: brightness,
          ),
        );
        await tester.pump();

        expect(find.text('README.md'), findsOneWidget);
        expect(abWidgetsInScope(tester), isEmpty);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }

  testWidgets('compact width has no Ab widget', (tester) async {
    await tester.pumpWidget(
      await _host(const AsyncData(FileTreeState(root: _tree)), width: 360),
    );
    await tester.pump();

    expect(find.text('src'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('empty tree has no Ab widget', (tester) async {
    await tester.pumpWidget(await _host(const AsyncData(FileTreeState())));
    await tester.pump();

    expect(find.text('No files available'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('error state has no Ab widget', (tester) async {
    await tester.pumpWidget(await _host(AsyncError('boom', StackTrace.empty)));
    await tester.pump();

    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('loading state has no Ab widget', (tester) async {
    await tester.pumpWidget(await _host(const AsyncLoading()));

    expect(find.byType(CarbonLoading), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('filter text typed in the field leaves no Ab widget', (
    tester,
  ) async {
    final t = FakeAgentTransport();
    await tester.pumpWidget(
      await _host(const AsyncData(FileTreeState(root: _tree)), transport: t),
    );
    await tester.pump();

    await tester.enterText(find.byType(EditableText).first, 'read');
    await tester.pump(FileService.findDebounce + const Duration(milliseconds: 20));
    final sent = t.sent.lastWhere((m) => m['type'] == 'file:find');
    t.emit('file:find-result', {
      'projectId': 'test',
      'requestId': sent['requestId'],
      'entries': const [],
      'truncated': false,
      'engine': 'git-ls-files',
    });
    await tester.pumpAndSettle();

    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the open search panel leaves no Ab widget', (tester) async {
    await tester.pumpWidget(
      await _host(const AsyncData(FileTreeState(root: _tree))),
    );
    await tester.pump();

    await tester.tap(_button('Search in files'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();

    expect(_button('Case Sensitive'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });

  testWidgets('the copy-path menu leaves no Ab widget', (tester) async {
    await tester.pumpWidget(
      await _host(const AsyncData(FileTreeState(root: _tree))),
    );
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('README.md')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Copy path'), findsOneWidget);
    expect(abWidgetsInScope(tester), isEmpty);
  });
}
