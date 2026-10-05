// The drawer scrolls the session on screen into view: a focused session whose
// row sits below the fold is brought up, once per activation, and a row
// already visible is left where it is.
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_agent_transport.dart';
import '../helpers/prefs_test_mock.dart';

const _projectId = 'proj-reveal';

SessionEntry _session(String id) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  late ScrollController scroll;

  /// A 300px drawer whose session row sits [lead] pixels down the list.
  Future<ProviderContainer> pumpDrawer(
    WidgetTester tester, {
    required double lead,
    String? activeBeforeMount,
  }) async {
    final transport = FakeAgentTransport();
    final cache = await CachedSessionsStore.open();
    final projectSession = ProjectSession(
      projectId: _projectId,
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await transport.dispose(),
    );
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue(_projectId),
        projectSessionProvider.overrideWith((ref, id) async => projectSession),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider(_projectId).future);
    if (activeBeforeMount != null) {
      container.read(activeSessionIdProvider.notifier).set(activeBeforeMount);
    }

    scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 260,
                height: 300,
                child: ListView(
                  controller: scroll,
                  // As the drawer's list does: a row must be built to reveal
                  // itself, and the default extent leaves one 800px down unbuilt.
                  scrollCacheExtent: const ScrollCacheExtent.pixels(4000),
                  children: [
                    SizedBox(height: lead),
                    SessionRow(entryId: _projectId, session: _session('s1')),
                    const SizedBox(height: 1000),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  bool rowFullyVisible(WidgetTester tester) {
    final row = tester.getRect(find.byType(SessionRow));
    return row.top >= 0 && row.bottom <= 300;
  }

  testWidgets('a row mounted already active scrolls into view', (
    tester,
  ) async {
    await pumpDrawer(tester, lead: 800, activeBeforeMount: 's1');

    expect(scroll.offset, greaterThan(0));
    expect(rowFullyVisible(tester), isTrue);
  });

  testWidgets('activating a row below the fold scrolls to it', (tester) async {
    final c = await pumpDrawer(tester, lead: 800);
    expect(scroll.offset, 0);

    c.read(activeSessionIdProvider.notifier).set('s1');
    await tester.pumpAndSettle();

    expect(rowFullyVisible(tester), isTrue);
  });

  testWidgets('an active row already on screen is not scrolled', (
    tester,
  ) async {
    await pumpDrawer(tester, lead: 40, activeBeforeMount: 's1');

    expect(scroll.offset, 0);
  });

  testWidgets('the reveal happens once per activation, not on every rebuild', (
    tester,
  ) async {
    final c = await pumpDrawer(tester, lead: 800, activeBeforeMount: 's1');

    // The user scrolls away from the session they are looking at.
    scroll.jumpTo(0);
    await tester.pumpAndSettle();
    c.read(activeSessionIdProvider.notifier).set('s1');
    await tester.pumpAndSettle();

    expect(scroll.offset, 0);
  });
}
