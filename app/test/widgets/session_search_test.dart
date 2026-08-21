// The session search is a title-bar field that drops its own result popup —
// it filters neither the sidebar nor the Recent list in place, so the popup IS
// the feature and these cover it end to end.
import 'package:antgrid/models/recent_session_row.dart';
import 'package:antgrid/models/session_entry.dart';
import 'package:antgrid/providers/recent_sessions.dart';
import 'package:antgrid/providers/session_search.dart';
import 'package:antgrid/widgets/session_search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/prefs_test_mock.dart';
import '../helpers/test_store_overrides.dart';

RecentSessionRow _row(String name, {String project = 'antgrid'}) =>
    RecentSessionRow(
      session: SessionEntry(
        id: 'id-$name',
        name: name,
        createdAt: 0,
        lastUsedAt: 0,
        archived: false,
        running: false,
      ),
      origin: RecentOrigin(
        isLocal: true,
        registrationId: project,
        projectId: project,
        machineUuid: null,
        projectName: project,
        deviceName: 'this-device',
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(useInMemoryPrefs);

  Future<void> pump(
    WidgetTester tester, {
    List<RecentSessionRow> rows = const [],
    double fieldWidth = 560,
  }) async {
    tester.view.physicalSize = const Size(1200, 800);
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
          home: Scaffold(
            // Top-aligned: the popup hangs BELOW the field, so a centred field
            // would push results off the bottom of the test surface.
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: fieldWidth,
                child: const SessionSearchField(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> focusField(WidgetTester tester) async {
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  }

  testWidgets('the popup stays shut until the field is focused', (
    tester,
  ) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    expect(find.byKey(SessionSearchField.popupKey), findsNothing);
  });

  // Focus, not the first keystroke: the resting popup is the recent list, so
  // there is something to pick from before anything is typed.
  testWidgets('focusing opens the popup on the recent list', (tester) async {
    await pump(
      tester,
      rows: [_row('Refactor the relay'), _row('Ship the installer')],
    );
    await focusField(tester);

    expect(find.byKey(SessionSearchField.popupKey), findsOneWidget);
    expect(find.text('Refactor the relay'), findsOneWidget);
    expect(find.text('Ship the installer'), findsOneWidget);
  });

  // Measured off the field, not fixed at the token: mobile's field is the width
  // of a phone, and a 560 panel centred under it would hang off both edges.
  testWidgets('the popup is exactly as wide as the field that opened it', (
    tester,
  ) async {
    await pump(tester, rows: [_row('Refactor the relay')], fieldWidth: 360);
    await focusField(tester);

    expect(tester.getSize(find.byKey(SessionSearchField.popupKey)).width, 360);
  });

  // A field narrower than the floor keeps a readable panel rather than dragging
  // the rows down to its own width.
  testWidgets('a squeezed field still gets a readable popup', (tester) async {
    await pump(tester, rows: [_row('Refactor the relay')], fieldWidth: 160);
    await focusField(tester);

    expect(tester.getSize(find.byKey(SessionSearchField.popupKey)).width, 280);
  });

  testWidgets('typing narrows the popup to matching sessions', (tester) async {
    await pump(
      tester,
      rows: [_row('Refactor the relay'), _row('Ship the installer')],
    );
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'RELAY');
    await tester.pumpAndSettle();

    expect(find.text('Refactor the relay'), findsOneWidget);
    expect(find.text('Ship the installer'), findsNothing);
  });

  testWidgets('a query nothing answers says so', (tester) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();

    expect(find.text('No sessions match.'), findsOneWidget);
    expect(find.text('Refactor the relay'), findsNothing);
  });

  // One key, both jobs: clear a box with text in it, close an empty one.
  testWidgets('escape clears first, then closes', (tester) async {
    await pump(tester, rows: [_row('Refactor the relay')]);
    await focusField(tester);

    await tester.enterText(find.byType(TextField), 'relay');
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(SessionSearchField.popupKey), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(SessionSearchField.popupKey), findsNothing);
  });

  test('sessionMatchesQuery is a case-insensitive name match', () {
    final s = _row('Refactor the Relay').session;
    expect(sessionMatchesQuery(s, 'relay'), isTrue);
    expect(sessionMatchesQuery(s, 'refactor'), isTrue);
    // The project id is NOT part of a session search.
    expect(sessionMatchesQuery(s, 'antgrid'), isFalse);
  });
}
