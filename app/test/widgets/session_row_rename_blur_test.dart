import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _projectId = 'proj-rename-blur';

SessionEntry _session(String id) => SessionEntry(
  id: id,
  name: 'Diagnose terminal scrollback bug',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  // Regression: blurring an inline rename used to take down the app with
  // `ConcurrentModificationError: Concurrent modification during iteration:
  // _Set len:N` (seen in production as a FATAL, culprit
  // `_CompactIterator.moveNext` under `FocusManager.applyFocusChangesIfNeeded`).
  //
  // The field's `onFocusChange` commits the rename, and `detached` runs that
  // through `Future.sync`, so `_exitEdit` executed INSIDE the focus
  // notification. Disposing its FocusNode there detaches it, and
  // `FocusManager._markDetached` removes it from `_dirtyNodes` — the Set the
  // notification loop is iterating.
  testWidgets('blurring an inline rename does not crash the focus manager', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final elsewhere = FocusNode(debugLabel: 'elsewhere');
    addTearDown(elsewhere.dispose);
    try {
      final transport = FakeAgentTransport();
      final cache = await CachedSessionsStore.open();
      addTearDown(cache.close);
      final projectSession = ProjectSession(
        projectId: _projectId,
        transport: transport,
        mode: ProjectSessionMode.local,
        cachedSessionsStore: cache,
        onClose: () async => await transport.dispose(),
      );
      // Registered after the cache so it tears down FIRST (addTearDown is
      // LIFO). Both own timers and stream subscriptions that would otherwise
      // outlive the widget tree and fail some later test with a pending-timer
      // assertion pointing nowhere near this file.
      addTearDown(projectSession.close);
      final container = ProviderContainer(
        overrides: [
          selectedRegistrationIdProvider.overrideWithValue(_projectId),
          projectSessionProvider.overrideWith(
            (ref, id) async => projectSession,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(projectSessionProvider(_projectId).future);
      // Inline rename is offered only for a WARM project, so the row cannot
      // enter edit mode until the registry knows about this one.
      container
          .read(projectSessionRegistryProvider.notifier)
          .touch(_projectId, isLocal: true);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  SizedBox(
                    width: 260,
                    child: SessionRow(
                      entryId: _projectId,
                      session: _session('sess-rename'),
                    ),
                  ),
                  // Somewhere for focus to GO. The bug needs a real focus
                  // change, not just an unfocus.
                  Focus(
                    focusNode: elsewhere,
                    child: const SizedBox(height: 20),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Double-tap opens the inline editor (desktop-only affordance).
      final row = find.byType(SessionRow);
      await tester.tap(row);
      await tester.pump(kDoubleTapMinTime);
      await tester.tap(row);
      await tester.pumpAndSettle();

      final field = find.byType(TextField);
      if (field.evaluate().isEmpty) {
        // Rename is gated on the project being warm; if this row cannot enter
        // edit mode the test is not exercising anything and must say so rather
        // than pass silently.
        fail('inline rename did not open — SessionRow never entered edit mode');
      }

      // The blur. Before the fix this threw out of the microtask that runs
      // `applyFocusChangesIfNeeded`.
      elsewhere.requestFocus();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byType(TextField), findsNothing);

      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
