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

const _projectId = 'proj-hover';

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

  Future<ProviderContainer> pumpRow(
    WidgetTester tester,
    FakeAgentTransport transport,
    SessionEntry sessionEntry,
  ) async {
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

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: SessionRow(entryId: _projectId, session: sessionEntry),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  group('SessionRow hover and sizing', () {
    testWidgets(
      'on desktop, kebab menu appears only on hover and row height never jitters',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          final transport = FakeAgentTransport();
          final session = _session('sess-1');
          await pumpRow(tester, transport, session);

          final rowFinder = find.byType(SessionRow);
          expect(rowFinder, findsOneWidget);

          // 1. Unhovered: kebab menu does NOT exist in the widget tree.
          expect(find.byTooltip('Session actions'), findsNothing);

          // Unhovered height is exactly 24px content + 2px padding + 2px margin = 28px.
          final unhoveredHeight = tester.getSize(rowFinder).height;
          expect(unhoveredHeight, 28.0);

          // 2. Hover over the row: kebab menu appears.
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(rowFinder));
          await tester.pump();

          expect(find.byTooltip('Session actions'), findsOneWidget);

          // Hovered height remains strictly identical (zero vertical jitter).
          final hoveredHeight = tester.getSize(rowFinder).height;
          expect(hoveredHeight, unhoveredHeight);

          // 3. Move mouse away: kebab menu vanishes again.
          await mouse.moveTo(const Offset(500, 500));
          await tester.pump();

          expect(find.byTooltip('Session actions'), findsNothing);
          expect(tester.getSize(rowFinder).height, unhoveredHeight);

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('on mobile, kebab menu is always present in tree', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final transport = FakeAgentTransport();
        final session = _session('sess-2');
        await pumpRow(tester, transport, session);

        expect(find.byTooltip('Session actions'), findsOneWidget);
        expect(tester.getSize(find.byType(SessionRow)).height, 28.0);

        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
