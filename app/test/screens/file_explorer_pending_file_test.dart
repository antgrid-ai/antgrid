// A location that names a file reaches the explorer as pending state, not as a
// call: the nav layer has no FileService to talk to. At launch the explorer is
// not mounted, and even once it is, the focused project's session — which owns
// the service — resolves asynchronously. So the drain has to survive both gaps
// and only spend the pending path once it can actually act on it.
import 'dart:async';

import 'package:antgrid/models/pending_nav.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/value_controller.dart';
import 'package:antgrid/providers/visible_surface.dart';
import 'package:antgrid/screens/file_explorer_screen.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/file_viewer_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Riverpod 3 keeps `Override` out of the main barrel.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

/// The harness leaves the selected target at its default, so a path the
/// explorer should open carries that same stamp.
PendingNav<String> _pending(String path) => (target: null, value: path);

/// [focusedCheckoutIdProvider] reads the checkout off the active session, so an
/// entry carrying a worktree id is how a test says "isolated".
const _worktreeSession = SessionEntry(
  id: 'session-1',
  name: 'Session',
  createdAt: 1,
  lastUsedAt: 1,
  archived: false,
  running: true,
  checkoutId: 'wt-1',
  checkoutKind: 'managed-worktree',
  checkoutBranch: 'antgrid/session-1',
);

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

/// Wide enough for the side-by-side layout, so the viewer pane is on screen and
/// the drain's effect is visible in the tree, not only in service state.
Future<ProviderContainer> _pumpExplorer(
  WidgetTester tester, {
  required List<Override> overrides,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox(width: 800, child: FileExplorerScreen())),
      ),
    ),
  );
  await _settle(tester);
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

/// The drain is deferred to a post-frame callback and clearing the pending path
/// schedules another build, so a single pump is not enough to observe the end
/// state.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump();
  }
}

void main() {
  // The launch-time case: the link is applied long before this screen exists,
  // so no change notification is coming and the mount has to find the value.
  testWidgets('a file pending before mount is opened and spent', (
    tester,
  ) async {
    final session = await _buildFakeSession();
    final container = await _pumpExplorer(
      tester,
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
        pendingFilePathProvider.overrideWith(
          () => ValueController(_pending('lib/main.dart')),
        ),
      ],
    );

    expect(
      session.fileService.currentState.files.selectedFilePath,
      'lib/main.dart',
    );
    expect(find.byType(FileViewerRouter), findsOneWidget);
    // Spent on consumption, so a later rebuild can't replay the link.
    expect(container.read(pendingFilePathProvider), isNull);
  });

  testWidgets('a file arriving while the explorer is up is opened', (
    tester,
  ) async {
    final session = await _buildFakeSession();
    final container = await _pumpExplorer(
      tester,
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
      ],
    );
    expect(session.fileService.currentState.files.selectedFilePath, isNull);

    container.read(pendingFilePathProvider.notifier).set(_pending('README.md'));
    await _settle(tester);

    expect(
      session.fileService.currentState.files.selectedFilePath,
      'README.md',
    );
    expect(container.read(pendingFilePathProvider), isNull);
  });

  // The gap a cold-start link actually lands in: the explorer builds while the
  // project's ProjectSession is still constructing, so there is no FileService
  // to open the file with. Dropping the path there would make the link a silent
  // no-op.
  testWidgets('a file pending on an unresolved session survives until it '
      'resolves', (tester) async {
    final session = await _buildFakeSession();
    final pending = Completer<ProjectSession>();
    final container = await _pumpExplorer(
      tester,
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => pending.future),
        pendingFilePathProvider.overrideWith(
          () => ValueController(_pending('lib/main.dart')),
        ),
      ],
    );
    expect(container.read(pendingFilePathProvider)?.value, 'lib/main.dart');
    expect(tester.takeException(), isNull);

    pending.complete(session);
    await _settle(tester);

    expect(
      session.fileService.currentState.files.selectedFilePath,
      'lib/main.dart',
    );
    expect(container.read(pendingFilePathProvider), isNull);
  });

  // The checkout comes from the ACTIVE SESSION, and a link naming an isolated
  // session leaves that id queued for _bootstrapSessions — until it lands,
  // focusedCheckoutId still answers `main`. Draining in that window opens the
  // path in the project's MAIN tree and spends it, so the link can never be
  // re-honoured: exactly what a checkout-relative path must never do.
  testWidgets('a file pending on an unsettled checkout waits for the session', (
    tester,
  ) async {
    final session = await _buildFakeSession();
    final container = await _pumpExplorer(
      tester,
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
        pendingFilePathProvider.overrideWith(
          () => ValueController(_pending('lib/main.dart')),
        ),
        pendingActiveSessionIdProvider.overrideWith(
          () => ValueController('session-1'),
        ),
      ],
    );

    expect(container.read(pendingFilePathProvider)?.value, 'lib/main.dart');
    expect(session.fileService.currentState.files.selectedFilePath, isNull);

    // The frame that settles the session is the retry — no second link needed.
    container.read(pendingActiveSessionIdProvider.notifier).set(null);
    await _settle(tester);

    expect(
      session.fileService.currentState.files.selectedFilePath,
      'lib/main.dart',
    );
    expect(container.read(pendingFilePathProvider), isNull);
  });

  // What the wait above buys: once the session lands, the file opens in the
  // worktree that session runs in, and the project's main tree is untouched.
  testWidgets('a file drains into the session checkout, not main', (
    tester,
  ) async {
    final session = await _buildFakeSession();
    await _pumpExplorer(
      tester,
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
        activeSessionProvider.overrideWithValue(_worktreeSession),
        pendingFilePathProvider.overrideWith(
          () => ValueController(_pending('lib/main.dart')),
        ),
      ],
    );

    expect(
      session.servicesForCheckout('wt-1').fileService.currentState
          .files
          .selectedFilePath,
      'lib/main.dart',
    );
    expect(session.fileService.currentState.files.selectedFilePath, isNull);
  });

  // Null is what a location naming no file writes; it must leave whatever the
  // explorer already had open exactly as it found it.
  testWidgets('a null pending file opens nothing', (tester) async {
    final session = await _buildFakeSession();
    final container = await _pumpExplorer(
      tester,
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue('test'),
        projectSessionProvider('test').overrideWith((ref) => session),
      ],
    );

    container.read(pendingFilePathProvider.notifier).set(null);
    await _settle(tester);

    expect(session.fileService.currentState.files.selectedFilePath, isNull);
    expect(find.byType(FileViewerRouter), findsNothing);
  });
}
