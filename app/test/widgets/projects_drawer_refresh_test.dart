// Verifies the machine-list refresh affordance in ProjectsDrawer:
//   tapping the refresh button in the PROJECTS group label re-fetches the
//   account inventory (accountAgentsProvider) so a newly-added remote machine
//   appears without an app restart.
//
// Local projects and QR-paired recent agents are already store-reactive; only
// the inventory FutureProvider loads once per session, so it's the one source
// the button needs to invalidate.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:antgrid/providers/account_agents.dart';
import 'package:antgrid/providers/auth.dart';
import 'package:antgrid/services/account_agents_api.dart';
import 'package:antgrid/widgets/projects_drawer.dart';

import '../helpers/test_store_overrides.dart';
import '../helpers/prefs_test_mock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStoreOverrides stores;

  setUp(() async {
    useInMemoryPrefs();
    stores = await buildTestStoreOverrides();
  });

  tearDown(() async {
    await stores.close();
  });

  testWidgets('tapping the PROJECTS refresh button re-fetches the inventory', (
    tester,
  ) async {
    var fetches = 0;
    Widget buildDrawer() => ProviderScope(
      overrides: [
        ...stores.overrides,
        accountAgentsProvider.overrideWith((ref) async {
          fetches++;
          return <InventoryAgent>[];
        }),
        currentUserProvider.overrideWith((_) async => null),
      ],
      child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
    );

    await tester.pumpWidget(buildDrawer());
    await tester.pumpAndSettle();
    expect(fetches, 1);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(fetches, 2);
  });

  // The button and the pull gesture are one interaction: the button shows the
  // list's RefreshIndicator rather than calling the handler behind its back, so
  // a tap gets the same spinner a pull does. Without this the button's only
  // answer was going dim for the length of a network round trip.
  testWidgets('the PROJECTS refresh button drives the pull-to-refresh '
      'indicator', (tester) async {
    final completer = Completer<List<InventoryAgent>>();
    var fetches = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...stores.overrides,
          accountAgentsProvider.overrideWith((ref) async {
            fetches++;
            // First load resolves so the drawer settles; the button's refresh
            // is held open so the indicator can be observed mid-flight.
            if (fetches > 1) return completer.future;
            return <InventoryAgent>[];
          }),
          currentUserProvider.overrideWith((_) async => null),
        ],
        child: const MaterialApp(home: Scaffold(body: ProjectsDrawer())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);

    await tester.tap(find.byTooltip('Refresh'));
    // Not pumpAndSettle: the indicator animates in before `onRefresh` fires,
    // and the fetch it starts is held open below — settling would hang.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(fetches, 2, reason: 'show() runs the pull gesture handler');
    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: 'a tap raises the same indicator a pull does',
    );

    completer.complete(<InventoryAgent>[]);
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });
}
