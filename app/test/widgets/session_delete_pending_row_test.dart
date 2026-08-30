// A delete runs for 3-15s on the bridge. The drawer row is the surface that has
// to say so: it stays visible, goes inert, and offers nothing that acts on a
// session already being taken apart.
import 'package:antgrid/design/widgets/ab_list_row.dart';
import 'package:antgrid/design/widgets/ab_loading.dart';
import 'package:antgrid/design/widgets/ab_status_dot.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/session_delete_pending.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import 'package:antgrid/test_helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';

const _projectId = 'p';

SessionEntry _session(String id, {bool deleting = false}) => SessionEntry(
  id: id,
  name: 'Session $id',
  createdAt: 0,
  lastUsedAt: 0,
  archived: false,
  running: true,
  deleting: deleting,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(useInMemoryPrefs);

  Future<ProviderContainer> pumpRows(
    WidgetTester tester,
    FakeAgentTransport transport,
    List<SessionEntry> sessions,
  ) async {
    final cache = await CachedSessionsStore.open();
    final session = ProjectSession(
      projectId: _projectId,
      transport: transport,
      mode: ProjectSessionMode.local,
      cachedSessionsStore: cache,
      onClose: () async => await transport.dispose(),
    );
    final container = ProviderContainer(
      overrides: [
        selectedRegistrationIdProvider.overrideWithValue(_projectId),
        projectSessionProvider.overrideWith((ref, id) async => session),
      ],
    );
    addTearDown(container.dispose);
    await container.read(projectSessionProvider(_projectId).future);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                for (final s in sessions)
                  SessionRow(entryId: _projectId, session: s),
              ],
            ),
          ),
        ),
      ),
    );
    // Not pumpAndSettle: the pending row pulses forever, by design.
    await tester.pump();
    await tester.pump();
    return container;
  }

  Finder rowFor(String id) =>
      find.byWidgetPredicate((w) => w is SessionRow && w.session.id == id);

  AbListRow listRowOf(WidgetTester tester, String id) =>
      tester.widget<AbListRow>(
        find.descendant(of: rowFor(id), matching: find.byType(AbListRow)),
      );

  bool kebabVisible(WidgetTester tester, String id) =>
      find
          .descendant(
            of: rowFor(id),
            matching: find.byTooltip('Session actions'),
          )
          .evaluate()
          .isNotEmpty;

  testWidgets('a deleting row is marked, pulsed, and inert', (tester) async {
    final transport = FakeAgentTransport();
    await pumpRows(tester, transport, [
      _session('a', deleting: true),
      _session('b'),
    ]);

    // Still on screen — the point is to show the delete, not to hide the row.
    expect(rowFor('a'), findsOneWidget);
    expect(find.text('DELETING'), findsOneWidget);

    // The leading slot swaps outright: work status is about a live agent.
    expect(
      find.descendant(of: rowFor('a'), matching: find.byType(AbLoadingDot)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: rowFor('a'), matching: find.byType(AbStatusDot)),
      findsNothing,
    );

    final deleting = listRowOf(tester, 'a');
    expect(deleting.enabled, isFalse);
    expect(deleting.onTap, isNull);
    expect(deleting.onDoubleTap, isNull);

    // Every kebab item acts on the session being removed, so the whole menu
    // goes — including the working-directory rows pointing into the checkout.
    expect(kebabVisible(tester, 'a'), isFalse);

    // A tap must not route the workspace at a session whose PTY is going away.
    await tester.tap(rowFor('a'), warnIfMissed: false);
    await tester.pump();
    expect(
      transport.sent.where(
        (m) => m['type'] == 'session:start' || m['type'] == 'session:focus',
      ),
      isEmpty,
    );

    // The sibling is untouched.
    final sibling = listRowOf(tester, 'b');
    expect(sibling.enabled, isTrue);
    expect(sibling.onTap, isNotNull);
    expect(
      find.descendant(of: rowFor('b'), matching: find.byType(AbLoadingDot)),
      findsNothing,
    );
    expect(kebabVisible(tester, 'b'), isTrue);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a row with no delete in flight carries no badge', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    await pumpRows(tester, transport, [_session('a')]);

    expect(find.text('DELETING'), findsNothing);
    expect(
      find.descendant(of: rowFor('a'), matching: find.byType(AbLoadingDot)),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
  });

  // The app's own in-flight mark has to render identically to the wire flag:
  // it is the whole pending signal until the bridge's first `session:updated`.
  testWidgets('an armed local mark renders the same as the wire flag', (
    tester,
  ) async {
    final transport = FakeAgentTransport();
    final container = await pumpRows(tester, transport, [_session('a')]);
    expect(find.text('DELETING'), findsNothing);

    container
        .read(sessionDeleteRequestsProvider.notifier)
        .arm(sessionDeleteKey(_projectId, 'a'));
    await tester.pump();

    expect(find.text('DELETING'), findsOneWidget);
    expect(listRowOf(tester, 'a').enabled, isFalse);
    expect(kebabVisible(tester, 'a'), isFalse);

    // Releases the mark's auto-expiry timer, which outlives the widget tree.
    container
        .read(sessionDeleteRequestsProvider.notifier)
        .disarm(sessionDeleteKey(_projectId, 'a'));
    await tester.pumpWidget(const SizedBox());
  });
}
