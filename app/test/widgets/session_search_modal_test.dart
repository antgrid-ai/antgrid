// Mobile's session search is a top-bar icon that opens a full-screen modal,
// not the desktop's inline field with a hanging popup — the two surfaces differ
// on purpose, so they are covered separately (see session_search_test.dart).
import 'package:antgrid/design/ab_tokens.dart';
import 'package:antgrid/design/theme_presets.dart';
import 'package:antgrid/design/widgets/ab_search_field.dart';
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/session_search.dart';
import 'package:antgrid/widgets/session_search_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

RecentSessionRow _row(String name) => RecentSessionRow(
  session: SessionEntry(
    id: 'id-$name',
    name: name,
    createdAt: 0,
    lastUsedAt: 0,
    archived: false,
    running: false,
  ),
  origin: const RecentOrigin(
    isLocal: true,
    registrationId: 'antgrid',
    projectId: 'antgrid',
    machineUuid: null,
    projectName: 'antgrid',
    deviceName: 'this-device',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  late ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    List<RecentSessionRow> rows = const [],
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final stores = await buildTestStoreOverrides();
    addTearDown(stores.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          recentSessionsProvider.overrideWithValue(rows),
        ],
        child: MaterialApp(
          theme: ThemeData.dark().copyWith(
            extensions: <ThemeExtension<dynamic>>[kDefaultPalette],
          ),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: SessionSearchButton(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    container = ProviderScope.containerOf(
      tester.element(find.byType(SessionSearchButton)),
    );
  }

  Future<void> openModal(WidgetTester tester) async {
    await tester.tap(find.byType(SessionSearchButton));
    await tester.pumpAndSettle();
  }

  testWidgets('the button shows nothing until it is tapped', (tester) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Refactor the relay'), findsNothing);
  });

  // The modal exists only to be typed into, so it opens keyboard-up, resting on
  // the recent list — same resting state as the desktop popup.
  testWidgets('tapping opens a focused modal on the recent list', (
    tester,
  ) async {
    await pump(
      tester,
      rows: [_row('Refactor the relay'), _row('Ship the installer')],
    );
    await openModal(tester);

    expect(find.text('Search sessions…'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus,
      isTrue,
    );
    expect(find.text('Refactor the relay'), findsOneWidget);
    expect(find.text('Ship the installer'), findsOneWidget);
  });

  testWidgets('typing narrows the modal to matching sessions', (tester) async {
    await pump(
      tester,
      rows: [_row('Refactor the relay'), _row('Ship the installer')],
    );
    await openModal(tester);

    await tester.enterText(find.byType(TextField), 'RELAY');
    await tester.pumpAndSettle();

    expect(find.text('Refactor the relay'), findsOneWidget);
    expect(find.text('Ship the installer'), findsNothing);
  });

  testWidgets('a query nothing answers says so', (tester) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    await openModal(tester);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No sessions match.'), findsOneWidget);
  });

  // Nothing survives the modal to show a stale query, so closing must reset it
  // — otherwise the next open comes back already filtered by a forgotten word.
  testWidgets('closing dismisses the modal and clears the query', (
    tester,
  ) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    await openModal(tester);

    await tester.enterText(find.byType(TextField), 'relay');
    await tester.pumpAndSettle();
    expect(container.read(sessionSearchQueryProvider), 'relay');

    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(container.read(sessionSearchQueryProvider), '');
  });

  // A full-screen surface, not a card floating over the canvas: the results
  // must have the whole screen, which is the entire reason mobile differs.
  testWidgets('the modal fills the screen', (tester) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    await openModal(tester);

    final dialog = tester.getSize(find.byType(Dialog));
    expect(dialog.width, 390);
    expect(dialog.height, 844);
    // Touch-sized input, not the title bar's pointer-sized row.
    expect(
      tester.widget<AbSearchField>(find.byType(AbSearchField)).height,
      AbTokens.rowHeightLg,
    );
  });
}
