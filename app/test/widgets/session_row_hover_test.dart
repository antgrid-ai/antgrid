import 'package:antgrid/design/ab_carbon.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/project/project_session.dart';
import 'package:antgrid/project/project_session_registry.dart';
import 'package:antgrid/providers/agent_transport.dart';
import 'package:antgrid/providers/sessions.dart';
import 'package:antgrid/providers/ui_attention_providers.dart';
import 'package:antgrid/storage/cached_sessions_store.dart';
import '../helpers/fake_agent_transport.dart';
import 'package:antgrid/widgets/session_row.dart';
import 'package:carbon_flutter/carbon_flutter.dart';
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
          home: AbCarbonScope(
            child: Scaffold(
              body: SizedBox(
                width: 260,
                child: SessionRow(entryId: _projectId, session: sessionEntry),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return container;
  }

  final kebab = find.byType(CarbonOverflowMenu);

  // The actions stay mounted so they stay focusable; what changes is whether
  // the cell that holds them is shown.
  bool kebabShown(WidgetTester tester) => tester
      .widget<Visibility>(
        find.ancestor(of: kebab, matching: find.byType(Visibility)).first,
      )
      .visible;

  bool selectedOf(WidgetTester tester) =>
      tester.widget<CarbonSideNavLink>(find.byType(CarbonSideNavLink)).current;

  group('SessionRow hover and sizing', () {
    testWidgets(
      'Scheduler clears the session highlight and returning restores it',
      (tester) async {
        final session = _session('scheduled-navigation');
        final container = await pumpRow(tester, FakeAgentTransport(), session);
        container.read(activeSessionIdProvider.notifier).set(session.id);
        await tester.pump();
        expect(selectedOf(tester), isTrue);

        container
            .read(workbenchSurfaceProvider.notifier)
            .set(WorkbenchSurface.scheduler);
        await tester.pump();
        expect(selectedOf(tester), isFalse);
        expect(container.read(activeSessionIdProvider), session.id);

        container
            .read(workbenchSurfaceProvider.notifier)
            .set(WorkbenchSurface.workspace);
        await tester.pump();
        expect(selectedOf(tester), isTrue);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'on desktop, the kebab is shown only on hover and row height never jitters',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await pumpRow(tester, FakeAgentTransport(), _session('sess-1'));

          final rowFinder = find.byType(SessionRow);
          expect(rowFinder, findsOneWidget);

          expect(kebabShown(tester), isFalse);

          // A 32px compact row: the actions cell holds its size while hidden, so
          // nothing below it moves when the pointer arrives.
          final restHeight = tester.getSize(rowFinder).height;
          expect(restHeight, 32.0);

          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(rowFinder));
          await tester.pump();

          expect(kebabShown(tester), isTrue);
          expect(tester.getSize(rowFinder).height, restHeight);

          await mouse.moveTo(const Offset(500, 500));
          await tester.pump();

          expect(kebabShown(tester), isFalse);
          expect(tester.getSize(rowFinder).height, restHeight);

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets('on mobile, the kebab is always shown in a 44pt row', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await pumpRow(tester, FakeAgentTransport(), _session('sess-2'));

        expect(kebabShown(tester), isTrue);
        expect(tester.getSize(find.byType(SessionRow)).height, 44.0);

        await tester.pumpWidget(const SizedBox());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets(
      'the kebab opens the session actions and stays revealed while the menu and a dialog are up',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        try {
          await pumpRow(tester, FakeAgentTransport(), _session('sess-3'));

          final rowFinder = find.byType(SessionRow);
          final mouse = await tester.createGesture(
            kind: PointerDeviceKind.mouse,
          );
          addTearDown(mouse.removePointer);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(rowFinder));
          await tester.pump();
          expect(kebabShown(tester), isTrue);

          await tester.tap(kebab);
          await tester.pumpAndSettle();

          expect(find.text('Stop'), findsOneWidget);
          expect(find.text('Rename'), findsOneWidget);
          expect(find.text('Delete'), findsOneWidget);

          // The pointer is over the menu, which sits outside the row.
          await mouse.moveTo(const Offset(600, 600));
          await tester.pump();
          expect(kebabShown(tester), isTrue);

          await tester.tap(find.text('Rename'));
          await tester.pumpAndSettle();

          // The dialog is hosted on a context that outlived the menu.
          expect(find.text('Rename session'), findsOneWidget);
          expect(kebabShown(tester), isTrue);

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();

          // The dialog hands focus back to the kebab, and focus inside the row
          // reveals it for keyboard users. Take focus away so only the menu and
          // dialog state is left to hold it open.
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
          // A stationary pointer is not re-hit-tested as overlays come and go,
          // so move it the way a user leaving the row would.
          await mouse.moveTo(const Offset(10, 500));
          await tester.pump();

          // Menu and dialog are gone and the pointer is away, so the kebab hides.
          expect(kebabShown(tester), isFalse);

          await tester.pumpWidget(const SizedBox());
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });
}
